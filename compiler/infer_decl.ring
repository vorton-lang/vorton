use types::{Type, Effect, EffectRow, RecordField, UNIT, EMPTY_ROW, type_to_string, effect_to_string, nominal_display_name, effects_match_kind, effect_kind_name, types_equal}
use ast::{Program, Decl, Expr, Param, TypeExpr, TypeParam, Span, Position, EffectOpDecl, EffectExpr,
    UseDecl}
use hir::{HDecl, HParam, HExpr, HStmt, HProgram, DerivedImpl, TraitBound, HAssocType,
    HStructField, HEnumVariant, HEffectOp, HTraitMethod, HFieldAccessKind,
    DictDispatchInfo, DictRef, trait_dict_name,
    make_intrinsic_method_call_ref, make_concrete_method_call_ref,
    make_bound_method_call_ref,
    hexpr_type, hexpr_effects, hexpr_span,
    collect_extern_type_names, compare_by_first, extern_abi_leaf}
use ir_identity::{NominalFieldRef, nominal_field_ref_index, symbol_ref_same,
    ImplOwnerRef, impl_owner_ref_provider, impl_owner_ref_trait,
    impl_owner_ref_same,
    impl_method_ref_member, symbol_ref_declaration_site_path,
    registered_trait_ref_symbol, trait_method_ref_trait,
    trait_method_ref_source_member_index,
    trait_method_ref_callable_slot_index, trait_method_ref_name}
use env::{TypeScheme, SchemeBound, AssocConstraintEntry,
    MethodOrigin, ImplEntry,
    ImplMethodSchemeCore,
    apply_subst, apply_subst_map, apply_subst_row_map,
    find_impl, find_impl_by_provider,
    find_impls_by_provider, find_delegate_child_provider_plan,
    optional_symbol_ref_same,
    delegate_child_provider_ref,
    delegate_child_provider_produced_owner_count,
    delegate_child_provider_had_semantic_error,
    has_impl, impl_origin,
    install_method_core, replace_impl_method_core,
    impl_method_core_as_scheme, impl_method_core_from_scheme,
    build_type_var_map}
use union_find::{UnionFind}
use unify::{empty_subst}
use diagnostics::{DiagnosticContext, DiagnosticNote}
use codes::{E0201, E0204, E0301, E0402, E0403, E0404, E0405, E0409, E0410, E0501, E0503, E0507, E0802, E0803}
use infer_ctx::{InferCtx, InferResult, FnBoundsEntry, AssocRebindEntry, CompileError,
    type_error, type_error_with_notes,
    unify_at, unify_at_noted, update_fn_effects,
    resolve_type_expr, resolve_self_type, resolve_dicts_from_scheme,
    resolve_dicts_from_impl_owner,
    pending_dict_checkpoint, drain_pending_dicts, rollback_pending_dicts,
    assert_pending_dict_owner_closed,
    generalize, collect_free_vars, free_type_vars_in_env, resolve_mod_uses,
    enter_project_root_frame, enter_project_child_frame,
    exit_project_namespace_frame,
    enter_impl_check_root_frame, enter_impl_check_child_frame,
    exit_impl_check_frame, impl_check_owner}
use infer_helpers::{is_value_type}
use resolver::{single_namespace_file_key}
use infer_register::{register_decls_two_phase, register_module_decls_two_phase,
    resolve_declared_effects, prefix_decl_name, insert_mod_aliases,
    collect_all_supertraits, inject_assoc_types_from_bounds,
    impl_owner_fn_bounds,
    resolve_trait_identity, resolve_nominal_identity}
use infer::{infer_block, infer_expr,
    register_bounded_callable_value_shadows}
use zonk::{ZonkCtx, zonk_type, zonk_row, zonk_param, zonk_block, zonk_expr}
use derive::{run_derive_pass}
use scc::{build_call_graph, tarjan_scc, collect_registered_fn_names, collect_self_method_callees}

// ============================================================
// Pass 2: Check declarations (from infer.ts)
// ============================================================

fn check_decl(
    mut ctx: InferCtx, decl: Decl, frame_decl_index: Int?
) -> HDecl {
    let obligation_checkpoint = pending_dict_checkpoint(ctx)
    let result = some(check_decl_inner(
        ctx, decl, frame_decl_index)) catch { _ => none }
    match result {
        some(hdecl) => {
            assert_pending_dict_owner_closed(ctx, obligation_checkpoint)
            hdecl
        },
        none => {
            rollback_pending_dicts(ctx, obligation_checkpoint)
            fail.raise(CompileError {})
        }
    }
}

fn check_decl_inner(
    mut ctx: InferCtx, decl: Decl, frame_decl_index: Int?
) -> HDecl {
    match decl {
        Decl::Struct { name, type_params, is_pub, span, .. } =>
            check_struct_decl(ctx, name, type_params, is_pub, span),
        Decl::Enum { name, type_params, is_pub, span, .. } =>
            check_enum_decl(ctx, name, type_params, is_pub, span),
        Decl::Effect { name, type_params, ops, is_pub, span } =>
            check_effect_decl(ctx, name, type_params, ops, is_pub, span),
        Decl::Impl { target_type, type_params, trait_name, methods, span } =>
            check_impl_decl(
                ctx, target_type, type_params, trait_name, methods, span,
                frame_decl_index.unwrap_or(-1)),
        Decl::Fn { name, type_params, params, return_type, declared_effects, body, is_pub, span, .. } =>
            check_fn_decl(ctx, name, type_params, params, return_type,
                declared_effects, body, is_pub, span, none, none, none),
        Decl::Test { description, body, span } =>
            check_test_decl(ctx, description, body, span),
        Decl::Trait { name, type_params, methods, is_pub, span, .. } =>
            check_trait_decl(ctx, name, type_params, methods, is_pub, span),
        Decl::ExternFn { name, type_params, params, return_type, declared_effects, is_pub, span } =>
            check_extern_fn_decl(ctx, name, type_params, params, declared_effects, is_pub, span),
        Decl::ExternType { name, type_params, is_pub, span } =>
            HDecl::ExternType { name: name, type_params: type_params, is_pub: is_pub, span: span },
        Decl::TypeAlias { name, is_pub, span, .. } => {
            let alias_type = match ctx.env.types.type_aliases.get(name) {
                some(alias) => alias.ty,
                none => UNIT
            }
            HDecl::TypeAlias { name: name, ty: alias_type, is_pub: is_pub, span: span }
        },
        Decl::Const { name, type_annotation, init, is_pub, span } =>
            check_const_decl(ctx, name, type_annotation, init, is_pub, span),
        Decl::ModBlock { name, uses, decls, required_effects, is_pub, span } =>
            check_mod_decl(
                ctx, name, uses, decls, required_effects,
                is_pub, span, frame_decl_index),
        Decl::EffectAlias { name, is_pub, span, .. } =>
            HDecl::TypeAlias { name: name, ty: UNIT, is_pub: is_pub, span: span },
        Decl::Delegate { span, .. } =>
            // Delegate is only valid inside impl blocks; handled by check_impl_decl
            HDecl::TypeAlias { name: "<delegate>", ty: UNIT, is_pub: false, span: span },
        Decl::AssocType { span, .. } =>
            // Associated types are only valid inside trait/impl blocks; handled there
            HDecl::TypeAlias { name: "<assoc_type>", ty: UNIT, is_pub: false, span: span }
    }
}

fn check_mod_decl_body(
    mut ctx: InferCtx, mod_name: Str, uses: List<UseDecl>,
    decls: List<Decl>, required_effects: List<EffectExpr>?,
    is_pub: Bool, span: Span, project_frame_active: Bool
) -> HDecl {
    // Register short-name aliases for mod-internal types so that
    // type annotations like `c: Circle` resolve to `shapes::Circle`.
    // These aliases remain in scope for the rest of the file, which
    // is acceptable because inline mods share the file scope.
    if !project_frame_active {
        insert_mod_aliases(ctx, mod_name, decls, false)
        // Resolve use declarations with relative paths (self::/super::)
        resolve_mod_uses(ctx, uses, true)
    }

    // Resolve required effects if present
    let mut cap_row: EffectRow? = none
    match required_effects {
        some(req_effs) => {
            cap_row = some(resolve_declared_effects(ctx, req_effs))
        },
        none => {}
    }

    // B-125: set mod_unsafe_allowed based on whether unsafe is in required effects
    match cap_row {
        some(cap) => {
            ctx.mod_unsafe_allowed = cap.effects.any(fn(e) {
                match e { Effect::UnsafeEffect => true, _ => false }
            })
        },
        none => {
            ctx.mod_unsafe_allowed = false
        }
    }

    let mut hdecls: List<HDecl> = []
    for decl_index in 0..decls.len() {
        let decl = decls.get(decl_index).unwrap()
        // Project extern types retain their foreign ABI identity. Registration
        // keeps only that raw source definition and the exact namespace frame
        // supplies its visible spelling; HIR must therefore use the same raw
        // identity. Single-file inline modules keep their legacy prefix.
        let prefixed = if project_frame_active {
            match decl {
                Decl::ExternType { .. } => decl,
                _ => prefix_decl_name(mod_name, decl)
            }
        } else {
            prefix_decl_name(mod_name, decl)
        }
        let result = some(check_decl(
            ctx, prefixed, some(decl_index))) catch { _ => none }
        match result {
            some(hd) => {
                // Update fn effects (same as check_one_decl)
                match hd {
                    HDecl::Fn { name, effects, .. } => {
                        if effects.effects.len() > 0 {
                            update_fn_effects(ctx.env, name, effects)
                        }
                    },
                    _ => {}
                }
                // Check capability restriction on function declarations
                match cap_row {
                    some(cap) => check_capability(ctx, hd, cap, span),
                    none => {}
                }
                let mut delegate_decls: List<HDecl> = []
                match prefixed {
                    Decl::Impl { methods, .. } => {
                        for source_member_index in 0..methods.len() {
                            match methods.get(source_member_index) {
                                some(Decl::Delegate {
                                    field, span: dspan, ..
                                }) => {
                                    let expanded = expand_delegate_impls(
                                        ctx, hd, source_member_index,
                                        field, dspan)
                                    for child in expanded {
                                        match cap_row {
                                            some(cap) => check_capability(
                                                ctx, child, cap, span),
                                            none => {}
                                        }
                                        delegate_decls.push(child)
                                    }
                                },
                                _ => {}
                            }
                        }
                    },
                    _ => {}
                }
                hdecls.push(hd)
                for child in delegate_decls { hdecls.push(child) }
            },
            none => {}
        }
    }
    HDecl::ModBlock { name: mod_name, decls: hdecls, is_pub: is_pub, span: span }
}

fn check_mod_decl(
    mut ctx: InferCtx, mod_name: Str, uses: List<UseDecl>,
    decls: List<Decl>, required_effects: List<EffectExpr>?,
    is_pub: Bool, span: Span, frame_decl_index: Int?
) -> HDecl {
    let project_active = ctx.project_namespace_file_key.is_some()
    let impl_decl_index = frame_decl_index.unwrap_or(-1)
    if impl_decl_index < 0 {
        panic("impl check index: inline module declaration index is missing")
    }
    enter_impl_check_child_frame(ctx, impl_decl_index)
    let mut entered_project_frame = false
    if project_active {
        entered_project_frame = match frame_decl_index {
            some(decl_index) => enter_project_child_frame(ctx, decl_index),
            none => false
        }
        if !entered_project_frame {
            panic("unreachable: resolver plan missing inline check frame")
        }
    }

    // Keep self/super path state paired with the exact namespace frame.
    let segments = mod_name.split("::")
    let simple_name = segments.get(segments.len() - 1).unwrap_or(mod_name)
    ctx.mod_path_stack.push(simple_name)
    let prev_unsafe_allowed = ctx.mod_unsafe_allowed
    let result = check_mod_decl_body(
        ctx, mod_name, uses, decls, required_effects,
        is_pub, span, project_active) catch { _ => {
            ctx.mod_unsafe_allowed = prev_unsafe_allowed
            let _ = ctx.mod_path_stack.pop()
            if entered_project_frame {
                let _ = exit_project_namespace_frame(ctx)
            }
            exit_impl_check_frame(ctx)
            fail.raise(CompileError {})
        }
    }
    ctx.mod_unsafe_allowed = prev_unsafe_allowed
    let _ = ctx.mod_path_stack.pop()
    if entered_project_frame {
        let _ = exit_project_namespace_frame(ctx)
    }
    exit_impl_check_frame(ctx)
    result
}

fn check_capability(mut ctx: InferCtx, decl: HDecl, cap: EffectRow, mod_span: Span) {
    match decl {
        HDecl::Fn { name, effects, span, .. } => {
            check_effects_capability(ctx, name, effects, cap, span)
        },
        HDecl::Impl { methods, .. } => {
            for method in methods {
                match method {
                    HDecl::Fn { name, effects, span, .. } => {
                        check_effects_capability(ctx, name, effects, cap, span)
                    },
                    _ => {}
                }
            }
        },
        _ => {}
    }
}

fn check_effects_capability(mut ctx: InferCtx, name: Str, effects: EffectRow, cap: EffectRow, span: Span) {
    for eff in effects.effects {
        let name_display = nominal_display_name(name)
        let kind_display = effect_to_string(eff)
        let in_cap = cap.effects.any(fn(c) { effects_match_kind(eff, c) })
        if !in_cap {
            let _ = type_error(ctx.sink, E0405,
                "'${name_display}' uses effect '${kind_display}' which is not in the module's requires set",
                span,
                DiagnosticContext::OtherContext { detail: some("capability violation") })
        }
    }
    // Note: an open effect row tail (type variable) represents effect
    // polymorphism — the function *may* carry additional effects depending
    // on its call site.  We do NOT reject open tails here because:
    //   1. The per-effect loop above already catches every *concrete* effect
    //      that is not in the capability set.
    //   2. A truly pure function (e.g. `fn id(x: Int) -> Int { x }`) has
    //      effects=[] with an open tail simply because the row was never
    //      closed — rejecting it would be a false positive.
    //   3. For genuinely polymorphic functions (e.g. accepting a callback
    //      with an open effect row), any concrete effect that flows through
    //      will surface in the *caller's* effect row and be caught by the
    //      per-effect check on that caller's declaration.
    //   This is why E0408 ("Open effect row in capability-restricted module")
    //   is defined but never emitted.
}

fn check_const_decl(mut ctx: InferCtx, name: Str, type_annotation: TypeExpr?, init: Expr, is_pub: Bool, span: Span) -> HDecl {
    let obligation_checkpoint = pending_dict_checkpoint(ctx)
    let saved_subst = ctx.subst
    ctx.subst = empty_subst()
    // Retrieve the def_id assigned during registration
    let old_def_id = match ctx.env.lookup(name) {
        some(sc) => sc.def_id,
        none => none
    }
    let mut expected_ty: Type? = none
    match type_annotation {
        some(texpr) => { expected_ty = some(resolve_type_expr(ctx, texpr)) },
        none => {}
    }
    let init_r = infer_expr(ctx, init, ctx.subst)
    let mut s = init_r.subst
    let mut init_ty = hexpr_type(init_r.hexpr)
    match expected_ty {
        some(ann_ty) => {
            s = unify_at(ctx.sink, ctx.env, init_ty, ann_ty, s, span)
            init_ty = apply_subst(s, ann_ty)
        },
        none => {}
    }
    // Annotation constraints are final for this const owner.  Callable-value
    // shadows join the same assoc fixed point without publishing DictRefs.
    register_bounded_callable_value_shadows(
        ctx, init_r.hexpr, s)
    drain_pending_dicts(ctx, obligation_checkpoint, s)
    // A const initializer is a value position.  Resolve its fully unified
    // function-value evidence before restoring the declaration substitution;
    // otherwise a bounded module function reaches codegen without its DictRef.
    let zctx = ZonkCtx {
        subst: s, names: map_new(),
        dict_resolver: some(ctx)
    }
    let resolved = zonk_type(zctx, init_ty)
    let zonked_init = some(zonk_expr(zctx, init_r.hexpr)) catch { _ => none }
    let final_init = match zonked_init {
        some(value) => value,
        none => {
            // Declaration-level recovery continues checking later declarations.
            // Never leak this const's isolated substitution through that path.
            rollback_pending_dicts(ctx, obligation_checkpoint)
            ctx.subst = saved_subst
            fail.raise(CompileError {})
        }
    }
    let gen_scheme = generalize(ctx.env, resolved, s)
    // Preserve the original def_id so mutability checks work
    let scheme = TypeScheme { ty: gen_scheme.ty, type_vars: gen_scheme.type_vars, bounds: gen_scheme.bounds, def_id: old_def_id }
    ctx.env.rebind(name, scheme)
    ctx.subst = saved_subst
    HDecl::Const { name: name, def_id: old_def_id, ty: resolved, init: final_init, is_pub: is_pub, span: span }
}

fn check_struct_decl(ctx: InferCtx, name: Str, type_params: List<TypeParam>, is_pub: Bool, span: Span) -> HDecl {
    let def = match ctx.env.types.structs.get(name) {
        some(d) => d,
        none => {
            let display = nominal_display_name(name)
            let _ = type_error(ctx.sink, E0204, "struct not found: ${display}", span,
                DiagnosticContext::OtherContext { detail: some("struct '${display}' was not registered") })
            fail.raise(CompileError {})
        }
    }
    let mut hfields: List<HStructField> = []
    for f in def.fields {
        hfields.push(HStructField {
            name: f.name, ty: f.ty, is_pub: f.is_pub,
            field_ref: f.field_ref, field_index: f.field_index,
            span: f.span
        })
    }
    HDecl::Struct {
        name: name, owner_ref: def.owner_ref,
        type_params: type_params, fields: hfields,
        is_pub: is_pub, span: span }
}

fn check_enum_decl(ctx: InferCtx, name: Str, type_params: List<TypeParam>, is_pub: Bool, span: Span) -> HDecl {
    let def = match ctx.env.types.enums.get(name) {
        some(d) => d,
        none => {
            let display = nominal_display_name(name)
            let _ = type_error(ctx.sink, E0204, "enum not found: ${display}", span,
                DiagnosticContext::OtherContext { detail: some("enum '${display}' was not registered") })
            fail.raise(CompileError {})
        }
    }
    let mut hvariants: List<HEnumVariant> = []
    for variant_index in 0..def.variants.len() {
        let v = def.variants.get(variant_index).unwrap()
        hvariants.push(HEnumVariant {
            name: v.name,
            variant_ref: def.variant_refs.get(variant_index).unwrap(),
            fields: v.fields,
            field_refs: def.variant_field_refs.get(variant_index).unwrap(),
            field_names: v.field_names
        })
    }
    HDecl::Enum {
        name: name, owner_ref: def.owner_ref,
        type_params: type_params, variants: hvariants,
        is_pub: is_pub, span: span
    }
}

fn check_effect_decl(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, ast_ops: List<EffectOpDecl>, is_pub: Bool, span: Span) -> HDecl {
    let def = match ctx.env.types.effects.get(name) {
        some(d) => d,
        none => {
            let display = nominal_display_name(name)
            let _ = type_error(ctx.sink, E0402, "effect not found: ${display}", span,
                DiagnosticContext::OtherContext { detail: some("effect '${display}' was not registered") })
            fail.raise(CompileError {})
        }
    }
    let mut hops: List<HEffectOp> = []
    let mut oi = 0
    for op in def.ops {
        let mut op_params: List<HParam> = []
        let mut pi = 0
        for pt in op.params {
            let p_name = match ast_ops.get(oi) {
                some(ast_op) => match ast_op.params.get(pi) {
                    some(ap) => ap.name,
                    none => "p${pi.to_str()}"
                },
                none => "p${pi.to_str()}"
            }
            let effect_param_def_id = ctx.env.fresh_def_id()
            op_params.push(HParam { name: p_name, ty: pt,
                def_id: some(effect_param_def_id), is_mutable: false })
            pi = pi + 1
        }
        // Type-check default body if present
        let ast_op_opt = ast_ops.get(oi)
        let mut default_body: HExpr? = none
        match ast_op_opt {
            some(ast_op) => match ast_op.body {
                some(body_expr) => {
                    let obligation_checkpoint = pending_dict_checkpoint(ctx)
                    // Bind op params in a new scope for type checking the default body
                    ctx.env.push_scope()
                    for p in op_params {
                        let exact_effect_def_id = match p.def_id {
                            some(id) => id,
                            none => panic(
                                "unreachable: effect default parameter has no exact DefId")
                        }
                        ctx.env.bind(p.name, TypeScheme {
                            ty: p.ty, type_vars: [], bounds: [],
                            def_id: some(exact_effect_def_id)
                        })
                    }
                    let checked_default = some({
                        let body_result = infer_block(ctx, body_expr, none)
                        ctx.subst = body_result.subst
                        let body_type = hexpr_type(body_result.hexpr)
                        ctx.subst = unify_at(
                            ctx.sink, ctx.env, body_type,
                            op.return_type, ctx.subst, span)
                        register_bounded_callable_value_shadows(
                            ctx, body_result.hexpr, ctx.subst)
                        drain_pending_dicts(
                            ctx, obligation_checkpoint, ctx.subst)
                        // Zonk only after the owner obligation transaction.
                        let zctx = ZonkCtx {
                            subst: ctx.subst, names: map_new(),
                            dict_resolver: some(ctx)
                        }
                        zonk_block(zctx, body_result.hexpr)
                    }) catch { _ => none }
                    let _ = ctx.env.pop_scope()
                    match checked_default {
                        some(checked_body) => {
                            assert_pending_dict_owner_closed(
                                ctx, obligation_checkpoint)
                            default_body = some(checked_body)
                        },
                        none => {
                            rollback_pending_dicts(
                                ctx, obligation_checkpoint)
                            fail.raise(CompileError {})
                        }
                    }
                },
                none => {},
            },
            none => {},
        }
        hops.push(HEffectOp {
            name: op.name, operation_ref: op.operation_ref,
            params: op_params, return_type: op.return_type,
            has_default: op.has_default, default_body: default_body
        })
        oi = oi + 1
    }

    // Validate default handler body effect dependencies:
    // Collect all custom effects used by default bodies and verify each has all_have_defaults.
    // Also record the dependency graph for cycle detection.
    let mut all_defaults = true
    for op in def.ops {
        if !op.has_default { all_defaults = false }
    }
    if all_defaults && def.ops.len() > 0 {
        let mut deps: List<Str> = []
        let mut dep_set: Set<Str> = set_new()
        for hop in hops {
            match hop.default_body {
                some(body) => {
                    let body_effs = hexpr_effects(body)
                    for eff in body_effs.effects {
                        let eff_name = effect_kind_name(eff)
                        // Skip: io (builtin), fail (builtin), mut (marker), self (same effect)
                        if eff_name == "io" || eff_name == "fail" || eff_name == "mut" || eff_name == name {
                            continue
                        }
                        // Check if the referenced effect has all defaults
                        match ctx.env.types.effects.get(eff_name) {
                            some(dep_def) => {
                                if !dep_def.all_have_defaults {
                                    let effect_display = nominal_display_name(name)
                                    let dep_display = nominal_display_name(eff_name)
                                    let _ = type_error(ctx.sink, E0409,
                                        "Default handler body of effect '${effect_display}' uses effect '${dep_display}' which has no default handler; all-default effects cannot depend on effects without defaults",
                                        span,
                                        DiagnosticContext::OtherContext { detail: some("default effect dependency violation") })
                                } else {
                                    if !dep_set.contains(eff_name) {
                                        dep_set.insert(eff_name)
                                        deps.push(eff_name)
                                    }
                                }
                            },
                            none => {}
                        }
                    }
                },
                none => {}
            }
        }
        if deps.len() > 0 {
            ctx.effect_default_deps.insert(name, deps)
        }
    }

    HDecl::Effect {
        name: name, owner_ref: def.owner_ref, handled_ref: def.handled_ref,
        type_params: type_params, ops: hops, is_pub: is_pub, span: span
    }
}

fn registered_impl_method_scheme(
    ctx: InferCtx, target_type: Str, trait_name: Str?,
    owner_ref: ImplOwnerRef, method_name: Str
) -> TypeScheme? {
    let _ = trait_name
    match find_impl_by_provider(
            ctx.env.trait_reg, target_type,
            impl_owner_ref_trait(owner_ref),
            impl_owner_ref_provider(owner_ref)) {
        some(entry) => match entry.owner_ref {
            some(found_owner) => if !impl_owner_ref_same(
                    found_owner, owner_ref) {
                panic("impl method scheme: typed owner changed")
            } else { match entry.method_schemes.get(method_name) {
                some(core) => some(impl_method_core_as_scheme(core)),
                none => none
            } },
            none => panic("impl method scheme: final owner has no identity")
        },
        none => none
    }
}

fn store_rebound_impl_method_scheme(
    mut ctx: InferCtx, target_type: Str, trait_name: Str?,
    owner_ref: ImplOwnerRef, method_name: Str, scheme: TypeScheme, span: Span
) {
    let owner = match find_impl_by_provider(
        ctx.env.trait_reg, target_type,
        impl_owner_ref_trait(owner_ref),
        impl_owner_ref_provider(owner_ref)) {
        some(entry) => match entry.owner_ref {
            some(found_owner) => if impl_owner_ref_same(
                    found_owner, owner_ref) { entry } else {
                panic("impl method rebind: typed owner changed")
            },
            none => panic("impl method rebind: final owner has no identity")
        },
        none => panic("impl method rebind: selected owner disappeared")
    }
    let provider_ref = impl_owner_ref_provider(owner_ref)
    let core = impl_method_core_from_scheme(scheme)
    replace_impl_method_core(
        ctx.env.trait_reg, target_type, owner_ref, method_name, core)
    let _ = install_method_core(
        ctx.env.trait_reg, ctx.sink,
        target_type, method_name, core,
        MethodOrigin {
            origin: owner.origin, trait_name: trait_name,
            provider_ref: provider_ref, trait_ref: owner.trait_ref,
            method_ref: owner.method_refs.get(method_name).unwrap(),
            span: span
        })
}

fn check_impl_decl(
    mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>,
    trait_name: Str?, methods: List<Decl>, span: Span, decl_index: Int
) -> HDecl {
    if decl_index < 0 {
        panic("impl checking: source declaration index is missing")
    }
    let selected_owner = impl_check_owner(ctx, decl_index)
    let canonical_target = resolve_nominal_identity(ctx, target_type)
    let canonical_trait = match trait_name {
        some(name) => some(resolve_trait_identity(ctx, name)), none => none
    }
    check_impl_decl_canonical(
        ctx, canonical_target, type_params, canonical_trait, methods, span,
        selected_owner)
}

fn check_impl_decl_canonical(
    mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>,
    trait_name: Str?, methods: List<Decl>, span: Span,
    selected_owner: ImplOwnerRef
) -> HDecl {
    for source_member in methods {
        match source_member {
            Decl::ExternFn { .. } => panic(
                "impl checking: forbidden extern member crossed parser"),
            _ => {}
        }
    }
    let impl_owner = match find_impl_by_provider(
        ctx.env.trait_reg, target_type,
        impl_owner_ref_trait(selected_owner),
        impl_owner_ref_provider(selected_owner)) {
        some(entry) => match entry.owner_ref {
            some(owner_ref) => if impl_owner_ref_same(
                    owner_ref, selected_owner) { entry } else {
                panic("impl checking: selected owner identity changed")
            },
            none => panic("impl checking: final owner has no typed identity")
        },
        none => fail.raise(CompileError {})
    }
    if !optional_symbol_ref_same(
            impl_owner.trait_ref, impl_owner_ref_trait(selected_owner)) {
        panic("impl checking: selected owner trait changed")
    }
    if impl_owner.type_param_vars.len() != type_params.len() ||
       impl_owner.type_params.len() != type_params.len() {
        panic("impl checking: owner type-parameter arity mismatch")
    }
    let saved_tp_scope = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    for index in 0..type_params.len() {
        match (type_params.get(index), impl_owner.type_param_vars.get(index),
               impl_owner.type_params.get(index)) {
            (some(tp), some(id), some(owner_name)) => {
                if tp.name != owner_name {
                    panic("impl checking: owner type-parameter order mismatch")
                }
                ctx.type_param_scope.insert(
                    tp.name, Type::TypeVar { id: id, name: some(tp.name) })
            },
            _ => panic("impl checking: owner type-parameter mapping is incomplete")
        }
    }

    let impl_self_type = if type_params.len() > 0 {
        let mut impl_tp_types: List<Type> = []
        for tp in type_params {
            match ctx.type_param_scope.get(tp.name) {
                some(tv) => impl_tp_types.push(tv),
                none => impl_tp_types.push(ctx.env.fresh_var())
            }
        }
        match ctx.env.types.structs.get(target_type) {
            some(def) => Type::StructType { name: def.name, type_params: impl_tp_types },
            none => match ctx.env.types.enums.get(target_type) {
                some(def) => Type::EnumType { name: def.name, type_params: impl_tp_types },
                none => resolve_self_type(ctx, target_type)
            }
        }
    } else {
        resolve_self_type(ctx, target_type)
    }

    // Inject Self into type_param_scope so Self::Item resolves in impl methods
    ctx.type_param_scope.insert("Self", impl_self_type)

    let saved_impl_bounds = ctx.current_fn_bounds
    let impl_bounds = impl_owner_fn_bounds(impl_owner)
    ctx.current_fn_bounds = impl_bounds
    for bound in ctx.current_fn_bounds {
        for constraint in bound.assoc_constraints {
            ctx.qualified_assoc_scope.insert(
                "${bound.type_param_name}::${constraint.name}",
                constraint.ty)
        }
    }

    // Collect associated types from impl
    let mut hassoc_types: List<HAssocType> = []
    for method in methods {
        match method {
            Decl::AssocType { name: aname, bounds: abounds, value: avalue, .. } => {
                let mut bound_names: List<Str> = []
                for b in abounds { bound_names.push(resolve_trait_identity(ctx, b.trait_name)) }
                let concrete = match avalue {
                    some(v) => some(resolve_type_expr(ctx, v)),
                    none => none
                }
                hassoc_types.push(HAssocType { name: aname, bounds: bound_names, concrete: concrete })
                // Inject concrete type into type_param_scope for method signature resolution
                match concrete {
                    some(ct) => {
                        ctx.type_param_scope.insert(aname, ct)
                        // Also inject Self::ItemName into qualified_assoc_scope
                        ctx.qualified_assoc_scope.insert("Self::${aname}", ct)
                    },
                    none => {}
                }
            },
            _ => {}
        }
    }

    // B-138: Reorder impl methods by SCC topological order so that callees
    // are checked before callers, enabling correct effect propagation.
    // Step 1: Collect Decl::Fn method names
    let mut impl_fn_names: Set<Str> = set_new()
    let mut impl_fn_map: Map<Str, Decl> = map_new()
    for method in methods {
        match method {
            Decl::Fn { name, .. } => {
                impl_fn_names.insert(name)
                impl_fn_map.insert(name, method)
            },
            _ => {}
        }
    }

    // Step 2: Build impl-internal call graph (self.method() edges)
    let mut impl_call_graph: Map<Str, List<Str>> = map_new()
    for method in methods {
        match method {
            Decl::Fn { name, body, .. } => {
                let mut callees: Set<Str> = set_new()
                collect_self_method_callees(body, impl_fn_names, callees)
                let mut sorted_callees: List<Str> = []
                for c in callees {
                    if c != name { sorted_callees.push(c) }
                }
                sorted_callees.sort()
                impl_call_graph.insert(name, sorted_callees)
            },
            _ => {}
        }
    }

    // Step 3: Run Tarjan SCC to get reverse topo order (callees first)
    let sccs = tarjan_scc(impl_call_graph)

    // Step 4: Build reordered method list — SCC-ordered Fn methods, then non-Fn decls
    let mut ordered_methods: List<Decl> = []
    let mut ordered_fn_names: Set<Str> = set_new()
    for scc in sccs {
        for name in scc {
            if !ordered_fn_names.contains(name) {
                match impl_fn_map.get(name) {
                    some(decl) => {
                        ordered_methods.push(decl)
                        ordered_fn_names.insert(name)
                    },
                    none => {}
                }
            }
        }
    }
    // Append non-Fn decls (ExternFn, AssocType, Delegate) in original order
    for method in methods {
        match method {
            Decl::Fn { .. } => {},  // Already in ordered_methods
            _ => ordered_methods.push(method)
        }
    }

    let mut hmethods: List<HDecl> = []
    for method in ordered_methods {
        match method {
            Decl::Fn { name, type_params: mtps, params, return_type, declared_effects, body, is_pub, span: mspan, .. } => {
                let registration_scheme = registered_impl_method_scheme(
                    ctx, target_type, trait_name, selected_owner, name)
                let exact_method = match impl_owner.method_refs.get(name) {
                    some(method_ref) => method_ref,
                    none => panic("impl checking: method has no exact identity")
                }
                let rebind_identity = symbol_ref_declaration_site_path(
                    impl_method_ref_member(exact_method))
                let hdecl = check_fn_decl(
                    ctx, name, mtps, params, return_type, declared_effects,
                    body, is_pub, mspan, some(impl_self_type),
                    registration_scheme, some(rebind_identity))
                // #210: Also register fn_mut_params with qualified key for cross-module export.
                // check_fn_decl inserts with unqualified `name`; exports.ring looks up
                // with "${target_type}_${mname}", so we mirror that key here.
                let qual_key = "${target_type}_${name}"
                match ctx.fn_mut_params.get(name) {
                    some(flags) => ctx.fn_mut_params.insert(qual_key, flags),
                    none => {}
                }
                match hdecl {
                    HDecl::Fn {
                        name: mname, params: mparams,
                        return_type: mret, effects: meffects,
                        span: checked_span, ..
                    } => match registration_scheme {
                        some(scheme) => {
                            let rebound = rebind_checked_fn_scheme(
                                ctx, rebind_identity, scheme,
                                mparams, mret, meffects, checked_span)
                            store_rebound_impl_method_scheme(
                                ctx, target_type, trait_name, selected_owner,
                                mname, rebound, checked_span)
                        }
                        none => {}
                    },
                    _ => {}
                }
                hmethods.push(hdecl)
            },
            Decl::Delegate { .. } => {},  // Handled at check_one_decl level
            Decl::AssocType { .. } => {},  // Already handled above
            _ => {}
        }
    }

    // B-002p1: impl Drop validation
    match trait_name {
        some(tn) => {
            if tn == "Drop" {
                // Drop + Clone conflict: a Drop type cannot also impl Clone
                if has_impl(ctx.env.trait_reg, target_type, "Clone") {
                    let target_display = nominal_display_name(target_type)
                    let _ = type_error(ctx.sink, E0802,
                        "type '${target_display}' cannot implement both Drop and Clone",
                        span, DiagnosticContext::TraitError { detail: "Drop and Clone are mutually exclusive" })
                }
                // Drop method must not have fail effect
                for hm in hmethods {
                    match hm {
                        HDecl::Fn { name: mname, effects: meff, span: mspan, .. } => {
                            if mname == "drop" {
                                for eff in meff.effects {
                                    match eff {
                                        Effect::FailEffect { .. } => {
                                            let _ = type_error(ctx.sink, E0803,
                                                "Drop::drop must not have fail effect",
                                                mspan, DiagnosticContext::TraitError { detail: "drop must not fail" })
                                        },
                                        _ => {}
                                    }
                                }
                            }
                        },
                        _ => {}
                    }
                }
                // Register this type as a Drop type
                ctx.drop_types.insert(target_type)
            }
            // Reverse check: Clone impl on a Drop type
            if tn == "Clone" {
                if has_impl(ctx.env.trait_reg, target_type, "Drop") || ctx.drop_types.contains(target_type) {
                    let target_display = nominal_display_name(target_type)
                    let _ = type_error(ctx.sink, E0802,
                        "type '${target_display}' cannot implement both Drop and Clone",
                        span, DiagnosticContext::TraitError { detail: "Drop and Clone are mutually exclusive" })
                }
            }
        },
        none => {}
    }

    ctx.current_fn_bounds = saved_impl_bounds
    ctx.type_param_scope = saved_tp_scope
    ctx.qualified_assoc_scope = saved_qualified_assoc
    let provider_ref = match impl_owner.provider_ref {
        some(value) => value,
        none => panic("impl HIR: selected final owner has no provider")
    }
    let owner_ref = match impl_owner.owner_ref {
        some(value) => value,
        none => panic("impl HIR: selected final owner has no typed identity")
    }
    HDecl::Impl {
        target_type: target_type,
        owner_ref: owner_ref,
        provider_ref: provider_ref, trait_ref: impl_owner.trait_ref,
        type_params: type_params, trait_name: trait_name,
        methods: hmethods, assoc_types: hassoc_types, span: span
    }
}

fn expand_delegate_impls(
    mut ctx: InferCtx, outer_impl: HDecl, source_member_index: Int,
    field: Str, span: Span
) -> List<HDecl> {
    let mut result: List<HDecl> = []
    let (target_type, type_params, outer_provider_ref, outer_trait_ref) =
        match outer_impl {
            HDecl::Impl {
                target_type, type_params, provider_ref, trait_ref, ..
            } => (target_type, type_params, provider_ref, trait_ref),
            _ => panic("delegate HIR: outer carrier is not an impl")
        }
    let outer_owner = match find_impl_by_provider(
        ctx.env.trait_reg, target_type, outer_trait_ref, outer_provider_ref
    ) {
        some(owner) => owner,
        none => panic("delegate HIR: outer typed owner is missing")
    }
    let child_plan = match find_delegate_child_provider_plan(
        outer_owner, source_member_index) {
        some(plan) => plan,
        none => panic("delegate HIR: raw child provider plan is missing")
    }
    let child_provider_ref = delegate_child_provider_ref(child_plan)
    let produced_owners = find_impls_by_provider(
        ctx.env.trait_reg, target_type, child_provider_ref)
    let produced_owner_count =
        delegate_child_provider_produced_owner_count(child_plan)
    let had_semantic_error =
        delegate_child_provider_had_semantic_error(child_plan)
    if produced_owners.len() != produced_owner_count {
        panic("delegate HIR: child provider owner count drifted")
    }
    if produced_owner_count == 0 {
        if had_semantic_error { return result }
        panic("delegate HIR: clean child provider produced no owners")
    }

    // Look up the field type from the struct definition
    match ctx.env.types.structs.get(target_type) {
        none => { result },  // Error already reported in Pass 1
        some(struct_def) => {
            let mut field_type: Type? = none
            let mut delegated_field_ref: NominalFieldRef? = none
            for f in struct_def.fields {
                if f.name == field {
                    field_type = some(f.ty)
                    delegated_field_ref = some(f.field_ref)
                }
            }
            match field_type {
                none => { result },  // Error already reported in Pass 1
                some(ft) => {
                    let exact_field_ref = match delegated_field_ref {
                        some(value) => value,
                        none => panic("delegate expansion lost exact field ref")
                    }
                    // Build self_type (same logic as check_impl_decl)
                    let self_type = if type_params.len() > 0 {
                        let mut impl_tp_types: List<Type> = []
                        for tp in type_params {
                            match ctx.type_param_scope.get(tp.name) {
                                some(tv) => impl_tp_types.push(tv),
                                none => impl_tp_types.push(ctx.env.fresh_var())
                            }
                        }
                        match ctx.env.types.structs.get(target_type) {
                            some(def) => Type::StructType { name: def.name, type_params: impl_tp_types },
                            none => match ctx.env.types.enums.get(target_type) {
                                some(def) => Type::EnumType { name: def.name, type_params: impl_tp_types },
                                none => resolve_self_type(ctx, target_type)
                            }
                        }
                    } else {
                        resolve_self_type(ctx, target_type)
                    }

                    // #125/#128: Get the field type name for looking up resolved methods
                    let field_type_name = match ft {
                        Type::StructType { name: n, .. } => some(n),
                        Type::EnumType { name: n, .. } => some(n),
                        _ => none
                    }
                    for produced_owner in produced_owners {
                        let produced_trait_name = match produced_owner.trait_name {
                            some(name) => name,
                            none => panic("delegate HIR: child owner is inherent")
                        }
                        let produced_trait_ref = match produced_owner.trait_ref {
                            some(reference) => reference,
                            none => panic("delegate HIR: child owner lost trait ref")
                        }
                        match ctx.env.trait_reg.traits.get(produced_trait_name) {
                            none => panic("delegate HIR: child trait is missing"),
                            some(trait_def) => {
                                if !symbol_ref_same(
                                        registered_trait_ref_symbol(
                                            trait_def.owner_ref),
                                        produced_trait_ref) {
                                    panic("delegate HIR: child trait identity changed")
                                }
                                let tname = produced_trait_name
                                let delegate_impl = some(produced_owner)
                                let field_impl = match field_type_name {
                                    some(ftn) => find_impl(
                                        ctx.env.trait_reg, ftn, tname),
                                    none => none
                                }
                                match field_impl {
                                    some(field_owner) => if !optional_symbol_ref_same(
                                            field_owner.trait_ref,
                                            some(produced_trait_ref)) {
                                        panic("delegate HIR: field trait identity changed")
                                    },
                                    none => {}
                                }

                                // Use the exact registered delegate receiver so
                                // HIR, method schemes, and dictionary bounds all
                                // share the same wrapper impl variables.
                                let mut exact_self_type = self_type
                                let mut found_exact_self = false
                                match delegate_impl {
                                    some(delegate_entry) => {
                                        let mut exact_entries =
                                            delegate_entry.method_schemes.entries()
                                        exact_entries.sort_by(compare_by_first)
                                        for exact_entry in exact_entries {
                                            if !found_exact_self {
                                                let (_, exact_core) = exact_entry
                                                let exact_scheme =
                                                    impl_method_core_as_scheme(
                                                        exact_core)
                                                match exact_scheme.ty {
                                                    Type::FnType { params, .. } =>
                                                        match params.first() {
                                                            some(receiver) => {
                                                                exact_self_type = receiver
                                                                found_exact_self = true
                                                            },
                                                            none => {}
                                                        },
                                                    _ => {}
                                                }
                                            }
                                        }
                                    },
                                    none => {}
                                }

                                let mut declared_params: List<Type> = []
                                let mut declared_index = 0
                                for declared_id in struct_def.type_param_vars {
                                    let declared_name = match
                                        struct_def.type_params.get(declared_index) {
                                        some(name) => some(name), none => none
                                    }
                                    declared_params.push(Type::TypeVar {
                                        id: declared_id, name: declared_name
                                    })
                                    declared_index = declared_index + 1
                                }
                                let declared_self_type = Type::StructType {
                                    name: struct_def.name,
                                    type_params: declared_params
                                }
                                let field_owner_map = build_type_var_map(
                                    declared_self_type, exact_self_type,
                                    struct_def.type_param_vars)
                                let resolved_ft = apply_subst_map(
                                    field_owner_map, ft)

                                // Derive one source-impl mapping from exact field
                                // receivers to the wrapper's actual field type.
                                let mut field_var_map: Map<Int, Type> = map_new()
                                match field_impl {
                                    some(field_entry) => {
                                        let mut field_methods =
                                            field_entry.method_schemes.entries()
                                        field_methods.sort_by(compare_by_first)
                                        for field_method in field_methods {
                                            let (_, field_core) = field_method
                                            let field_scheme =
                                                impl_method_core_as_scheme(
                                                    field_core)
                                            match field_scheme.ty {
                                                Type::FnType { params, .. } =>
                                                    match params.first() {
                                                        some(field_receiver) => {
                                                            let candidate = build_type_var_map(
                                                                field_receiver, resolved_ft,
                                                                field_scheme.type_vars)
                                                            let mut source_ids = candidate.keys()
                                                            source_ids.sort()
                                                            for source_id in source_ids {
                                                                match candidate.get(source_id) {
                                                                    some(mapped) =>
                                                                        field_var_map.insert(
                                                                            source_id, mapped),
                                                                    none => {}
                                                                }
                                                            }
                                                        },
                                                        none => {}
                                                    },
                                                _ => {}
                                            }
                                        }
                                    },
                                    none => {}
                                }

                                let mut generated_trait_bounds: List<TraitBound> = []
                                let mut generated_fn_bounds: List<FnBoundsEntry> = []
                                match delegate_impl {
                                    some(delegate_entry) => {
                                        generated_fn_bounds =
                                            impl_owner_fn_bounds(delegate_entry)
                                        for bound in generated_fn_bounds {
                                            generated_trait_bounds.push(TraitBound {
                                                type_param: bound.type_param_name,
                                                trait_name: bound.trait_name
                                            })
                                        }
                                    },
                                    none => {}
                                }

                                // #128: Look up field type's exact ImplEntry for assoc_types
                                let mut field_assoc_map: Map<Str, Type> = map_new()
                                match field_impl {
                                    some(field_entry) => {
                                        let mut assoc_entries =
                                            field_entry.assoc_types.entries()
                                        assoc_entries.sort_by(compare_by_first)
                                        for assoc_entry in assoc_entries {
                                            let (assoc_name, assoc_type) = assoc_entry
                                            field_assoc_map.insert(
                                                assoc_name,
                                                apply_subst_map(
                                                    field_var_map, assoc_type))
                                        }
                                    },
                                    none => {}
                                }

                                let mut trait_hmethods: List<HDecl> = []
                                for tm in trait_def.methods {
                                    // The wrapper ImplEntry owns the specialized
                                    // public signature; the field ImplEntry owns
                                    // the forwarded callee and its predicates.
                                    let resolved_method_scheme = match delegate_impl {
                                        some(wrapper_entry) =>
                                            match wrapper_entry.method_schemes.get(tm.name) {
                                                some(core) => some(
                                                    impl_method_core_as_scheme(core)),
                                                none => none
                                            },
                                        none => none
                                    }
                                    let field_method_scheme = match field_impl {
                                        some(field_entry) =>
                                            match field_entry.method_schemes.get(tm.name) {
                                                some(core) => some((
                                                    core,
                                                    impl_method_core_as_scheme(core))),
                                                none => none
                                            },
                                        none => none
                                    }
                                    match tm.ty {
                                        Type::FnType { params: trait_params, return_type: trait_ret_ty, effects: trait_eff } => {
                                            // Use resolved return type and effects from field type's method
                                            // if available (concrete assoc types), else fall back to trait def
                                            let ret_ty = match resolved_method_scheme {
                                                some(rs) => match rs.ty {
                                                    Type::FnType { return_type: resolved_ret, .. } => resolved_ret,
                                                    _ => trait_ret_ty
                                                },
                                                none => trait_ret_ty
                                            }
                                            let eff = match resolved_method_scheme {
                                                some(rs) => match rs.ty {
                                                    Type::FnType { effects: resolved_eff, .. } => resolved_eff,
                                                    _ => trait_eff
                                                },
                                                none => trait_eff
                                            }
                                            // Build resolved param types from field method (skipping self)
                                            let resolved_non_self_params = match resolved_method_scheme {
                                                some(rs) => match rs.ty {
                                                    Type::FnType { params: rp, .. } => some(rp),
                                                    _ => none
                                                },
                                                none => none
                                            }
                                            // Build HParam list: first is self, rest are synthetic params
                                            let mut hparams: List<HParam> = []
                                            let def_id_self = ctx.env.fresh_def_id()
                                            // #77: Read self mutability from trait method declaration
                                            let self_is_mut = match tm.param_mutabilities.get(0) {
                                                some(m) => m,
                                                none => false
                                            }
                                            hparams.push(HParam { name: "self", ty: exact_self_type, def_id: some(def_id_self), is_mutable: self_is_mut })

                                            // Determine the trait's Self type (first param) for binary method detection
                                            let trait_self_type = match trait_params.first() {
                                                some(t) => t,
                                                none => UNIT
                                            }

                                            // Build args for the forwarding call (beyond self)
                                            let mut forward_args: List<HExpr> = []
                                            let mut pi = 1
                                            while pi < trait_params.len() {
                                                let pname = "__p${pi - 1}"
                                                let pty = match trait_params.get(pi) {
                                                    some(t) => t,
                                                    none => UNIT
                                                }
                                                // #125: Use resolved param type from field method if available
                                                // (resolves assoc type vars to concrete types)
                                                let resolved_pty = match resolved_non_self_params {
                                                    some(rp) => match rp.get(pi) {
                                                        some(rpt) => rpt,
                                                        none => pty
                                                    },
                                                    none => pty
                                                }
                                                let pid = ctx.env.fresh_def_id()
                                                // #77: Read param mutability from trait method declaration
                                                let p_is_mut = match tm.param_mutabilities.get(pi) {
                                                    some(m) => m,
                                                    none => false
                                                }

                                                // #79: For binary trait methods (e.g. eq(self, other: Self)),
                                                // if the param type is the trait's Self type, forward arg.field
                                                // instead of arg so the field type's method receives the right value.
                                                // Use original trait type vars (pty) for this check.
                                                let is_self_typed = match (pty, trait_self_type) {
                                                    (Type::TypeVar { id: a, .. }, Type::TypeVar { id: b, .. }) => a == b,
                                                    _ => false
                                                }
                                                // For binary Self-typed params, use self_type; otherwise use resolved type
                                                let param_ty = if is_self_typed { exact_self_type } else { resolved_pty }
                                                hparams.push(HParam { name: pname, ty: param_ty, def_id: some(pid), is_mutable: p_is_mut })

                                                if is_self_typed {
                                                    // Forward: __p0.field (access the delegated field from the arg)
                                                    let arg_ident = HExpr::Ident {
                                                        name: pname, resolved_name: none, def_id: some(pid),
                                                        dict_closure_dicts: none,
                                                        ty: exact_self_type, effects: EMPTY_ROW, span: span
                                                    }
                                                    forward_args.push(HExpr::FieldAccess {
                                                        receiver: arg_ident,
                                                        field: field,
                                                        access_kind: HFieldAccessKind::NominalField {
                                                            owner_ref: struct_def.owner_ref,
                                                            field_ref: exact_field_ref,
                                                            field_index: nominal_field_ref_index(
                                                                exact_field_ref)
                                                        },
                                                        ty: resolved_ft,
                                                        effects: EMPTY_ROW,
                                                        span: span
                                                    })
                                                } else {
                                                    forward_args.push(HExpr::Ident {
                                                        name: pname, resolved_name: none, def_id: some(pid),
                                                        dict_closure_dicts: none,
                                                        ty: resolved_pty, effects: EMPTY_ROW, span: span
                                                    })
                                                }
                                                pi = pi + 1
                                            }

                                            // Build: self.field
                                            let field_access = HExpr::FieldAccess {
                                                receiver: HExpr::Ident {
                                                    name: "self", resolved_name: none, def_id: some(def_id_self),
                                                    dict_closure_dicts: none,
                                                    ty: exact_self_type, effects: EMPTY_ROW, span: span
                                                },
                                                field: field,
                                                access_kind: HFieldAccessKind::NominalField {
                                                    owner_ref: struct_def.owner_ref,
                                                    field_ref: exact_field_ref,
                                                    field_index: nominal_field_ref_index(
                                                        exact_field_ref)
                                                },
                                                ty: resolved_ft,
                                                effects: EMPTY_ROW,
                                                span: span
                                            }

                                            // #68: Check if this method is a default method without explicit impl
                                            // on the field type. If so, use trait dict dispatch instead of UFCS.
                                            let mut use_dict_dispatch = false
                                            if tm.has_default {
                                                // Get the field type name
                                                let ftn = match resolved_ft {
                                                    Type::StructType { name: n, .. } => some(n),
                                                    Type::EnumType { name: n, .. } => some(n),
                                                    _ => none
                                                }
                                                match ftn {
                                                    some(field_tn) => {
                                                        // Check if the field type has an explicit impl for this method
                                                        let mut has_explicit = false
                                                        match field_impl {
                                                            some(field_entry) => {
                                                                has_explicit = field_entry.method_names.contains(tm.name)
                                                            },
                                                            none => {}
                                                        }
                                                        if !has_explicit {
                                                            use_dict_dispatch = true
                                                        }
                                                    },
                                                    none => {}
                                                }
                                            }

                                            let call_expr = if use_dict_dispatch {
                                                // Generate dict dispatch: __FieldType_Trait.method(self.field, args...)
                                                let ftn = match resolved_ft {
                                                    Type::StructType { name: n, .. } => n,
                                                    Type::EnumType { name: n, .. } => n,
                                                    _ => ""
                                                }
                                                let dict_name = trait_dict_name(ftn, tname)
                                                let mut dict_args: List<HExpr> = []
                                                dict_args.push(field_access)
                                                dict_args.extend(forward_args)
                                                HExpr::Call {
                                                    callee: HExpr::Ident {
                                                        name: dict_name, resolved_name: none, def_id: none,
                                                        dict_closure_dicts: none,
                                                        ty: tm.ty, effects: EMPTY_ROW, span: span
                                                    },
                                                    args: dict_args,
                                                    type_args: [],
                                                    resolved_dicts: [],
                                                    dict_dispatch: some(DictDispatchInfo {
                                                        dict_ref: DictRef::Static(dict_name),
                                                        method: tm.name
                                                    }),
                                                    method_ref: some(
                                                        make_bound_method_call_ref(
                                                            tm.method_ref, tm.ty,
                                                            tm.param_mutabilities.first().unwrap_or(false))),
                                                    ty: ret_ty,
                                                    effects: eff,
                                                    span: span
                                                }
                                            } else {
                                                let resolved_forward_dicts = match (field_impl, field_method_scheme) {
                                                    (some(field_owner), some((field_core, field_scheme))) => {
                                                        let field_callee_type = apply_subst_map(
                                                            field_var_map, field_scheme.ty)
                                                        resolve_dicts_from_impl_owner(
                                                            ctx.sink, ctx.env,
                                                            generated_fn_bounds,
                                                            field_owner, field_core,
                                                            field_callee_type,
                                                            ctx.subst, span)
                                                    },
                                                    _ => []
                                                }
                                                // Build: self.field.method — as FieldAccess for UFCS dispatch
                                                let method_access = HExpr::FieldAccess {
                                                    receiver: field_access,
                                                    field: tm.name,
                                                    access_kind: HFieldAccessKind::Method,
                                                    ty: tm.ty,
                                                    effects: EMPTY_ROW,
                                                    span: span
                                                }

                                                // Build: self.field.method(args...) — as Call with UFCS callee
                                                let exact_forward_ref = match field_impl {
                                                    some(field_owner) => match
                                                            field_owner.method_intrinsics.get(tm.name) {
                                                        some(intrinsic) =>
                                                            make_intrinsic_method_call_ref(
                                                                intrinsic, tm.ty),
                                                        none => match
                                                                field_owner.method_refs.get(tm.name) {
                                                            some(method_ref) =>
                                                                make_concrete_method_call_ref(
                                                                    method_ref, tm.ty,
                                                                    tm.param_mutabilities.first().unwrap_or(false)),
                                                            none => panic(
                                                                "delegate HIR: field owner lost exact method")
                                                        }
                                                    },
                                                    none => panic(
                                                        "delegate HIR: field owner is missing")
                                                }
                                                HExpr::Call {
                                                    callee: method_access,
                                                    args: forward_args,
                                                    type_args: [],
                                                    resolved_dicts: resolved_forward_dicts,
                                                    dict_dispatch: none,
                                                    method_ref: some(exact_forward_ref),
                                                    ty: ret_ty,
                                                    effects: eff,
                                                    span: span
                                                }
                                            }

                                            trait_hmethods.push(HDecl::Fn {
                                                name: tm.name,
                                                def_id: some(ctx.env.fresh_def_id()),
                                                // #77: Copy method type_params from trait method declaration
                                                type_params: tm.method_type_params,
                                                params: hparams,
                                                return_type: ret_ty,
                                                effects: eff,
                                                body: call_expr,
                                                is_pub: false,
                                                trait_bounds: generated_trait_bounds,
                                                span: span
                                            })
                                        },
                                        _ => {}
                                    }
                                }

                                // #128: Build HAssocType list from field type's assoc_types
                                let mut h_assoc_types: List<HAssocType> = []
                                let mut sorted_assoc = field_assoc_map.entries()
                                sorted_assoc.sort_by(compare_by_first)
                                for entry in sorted_assoc {
                                    let (aname, aty) = entry
                                    h_assoc_types.push(HAssocType { name: aname, bounds: [], concrete: some(aty) })
                                }

                                let selected_delegate_owner = match delegate_impl {
                                    some(owner) => owner,
                                    none => panic(
                                        "delegate HIR: selected owner is missing")
                                }
                                let selected_delegate_provider = match
                                        selected_delegate_owner.provider_ref {
                                    some(provider) => provider,
                                    none => panic(
                                        "delegate HIR: final owner has no provider")
                                }
                                let selected_delegate_ref = match
                                        selected_delegate_owner.owner_ref {
                                    some(owner) => owner,
                                    none => panic(
                                        "delegate HIR: final owner has no typed identity")
                                }
                                result.push(HDecl::Impl {
                                    target_type: target_type,
                                    owner_ref: selected_delegate_ref,
                                    provider_ref: selected_delegate_provider,
                                    trait_ref: selected_delegate_owner.trait_ref,
                                    type_params: type_params,
                                    trait_name: some(tname),
                                    methods: trait_hmethods,
                                    assoc_types: h_assoc_types,
                                    span: span
                                })
                            }
                        }
                    }
                    result
                }
            }
        }
    }
}

fn check_trait_decl(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, ast_methods: List<Decl>, is_pub: Bool, span: Span) -> HDecl {
    let trait_def = match ctx.env.trait_reg.traits.get(name) {
        some(d) => d,
        none => {
            let display = nominal_display_name(name)
            let _ = type_error(ctx.sink, E0501, "trait not found: ${display}", span,
                DiagnosticContext::TraitError { detail: "trait '${display}' was not registered" })
            fail.raise(CompileError {})
        }
    }

    let mut self_var: Type = ctx.env.fresh_var()
    if trait_def.methods.len() > 0 {
        match trait_def.methods.first() {
            some(first_method) => match first_method.ty {
                Type::FnType { params: fps, .. } => {
                    if fps.len() > 0 {
                        match fps.first() { some(fp) => { self_var = fp }, none => {} }
                    }
                },
                _ => {}
            },
            none => {}
        }
    }

    let mut hmethods: List<HTraitMethod> = []
    for method_index in 0..trait_def.methods.len() {
        let m = trait_def.methods.get(method_index).unwrap()
        let source_member_index =
            trait_method_ref_source_member_index(m.method_ref)
        if !symbol_ref_same(
                trait_method_ref_trait(m.method_ref),
                registered_trait_ref_symbol(trait_def.owner_ref)) ||
           trait_method_ref_callable_slot_index(m.method_ref) != method_index ||
           source_member_index < method_index ||
           trait_method_ref_name(m.method_ref) != m.name {
            panic("trait HIR: exact method relation drifted")
        }
        let ast_method = match ast_methods.get(source_member_index) {
            some(method) => match method {
                Decl::Fn { name: source_name, is_abstract, .. } => {
                    if source_name != m.name || m.has_default == is_abstract {
                        panic("trait HIR: exact source method shape drifted")
                    }
                    method
                },
                _ => panic("trait HIR: exact source member is not a method")
            },
            none => panic("trait HIR: exact source member is missing")
        }
        let fn_params: List<Type> = match m.ty {
            Type::FnType { params, .. } => params,
            _ => []
        }
        let fn_ret = match m.ty {
            Type::FnType { return_type, .. } => return_type,
            _ => UNIT
        }
        let fn_effects = match m.ty {
            Type::FnType { effects, .. } => effects,
            _ => EMPTY_ROW
        }
        let ast_params = match ast_method {
            Decl::Fn { params, .. } => params,
            _ => panic("trait HIR: exact source member changed kind")
        }
        if ast_params.len() != fn_params.len() ||
           m.param_mutabilities.len() != ast_params.len() {
            panic("trait HIR: exact source parameter shape drifted")
        }

        let mut hparams: List<HParam> = []
        let mut pi = 0
        for param_type in fn_params {
            let source_param = match ast_params.get(pi) {
                some(param) => param,
                none => panic("trait HIR: exact source parameter is missing")
            }
            let trait_param_def_id = ctx.env.fresh_def_id()
            hparams.push(HParam { name: source_param.name, ty: param_type,
                def_id: some(trait_param_def_id),
                is_mutable: source_param.is_mutable })
            pi = pi + 1
        }

        let mut method_body: HExpr? = none
        if m.has_default {
            match ast_method {
                Decl::Fn { body: abody, span: method_span, .. } => {
                    let has_body = match abody {
                        Expr::Block { stmts, tail, .. } => stmts.len() > 0 || tail.is_some(),
                        _ => true
                    }
                    if has_body {
                        let method_identity = "${name}::${m.name}"
                        method_body = check_trait_default_body(
                            ctx, name, method_identity,
                            self_var, hparams, fn_ret, fn_effects,
                            method_span, abody)
                    }
                },
                _ => panic("trait HIR: exact default method changed kind")
            }
        }

        hmethods.push(HTraitMethod {
            name: m.name, method_ref: m.method_ref,
            params: hparams, return_type: fn_ret,
            effects: fn_effects, has_default: m.has_default,
            body: method_body
        })
    }

    // Build HAssocType list from trait def
    let mut hassoc_types: List<HAssocType> = []
    for atdef in trait_def.assoc_types {
        hassoc_types.push(HAssocType { name: atdef.name, bounds: atdef.bounds, concrete: atdef.default_type })
    }

    HDecl::Trait {
        name: name, owner_ref: trait_def.owner_ref,
        type_params: type_params, methods: hmethods,
        supertraits: trait_def.supertraits,
        assoc_types: hassoc_types, is_pub: is_pub, span: span
    }
}

fn check_trait_default_body(
    mut ctx: InferCtx, trait_name: Str, method_identity: Str,
    self_var: Type, hparams: List<HParam>, method_return: Type,
    method_effects: EffectRow, method_span: Span, body: Expr
) -> HExpr? {
    let obligation_checkpoint = pending_dict_checkpoint(ctx)
    let saved_subst = ctx.subst
    let saved_fn_return = ctx.current_fn_return_type
    ctx.subst = empty_subst()
    // Trait defaults are function owners too.  Keep the declared return live
    // during inference so explicit returns constrain pending call variables.
    ctx.current_fn_return_type = some(method_return)
    ctx.env.push_scope()
    let saved_tp_scope = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    ctx.fn_bounds_stack.push(ctx.current_fn_bounds)
    ctx.current_fn_bounds = []

    match self_var {
        Type::TypeVar { id, .. } => {
            ctx.current_fn_bounds.push(FnBoundsEntry {
                type_param_var_id: id, trait_name: trait_name,
                type_param_name: "self", assoc_constraints: []
            })
            // Expand supertrait bounds for trait default body
            let supers = collect_all_supertraits(ctx, trait_name)
            for st_name in supers {
                ctx.current_fn_bounds.push(FnBoundsEntry {
                    type_param_var_id: id, trait_name: st_name,
                    type_param_name: "self", assoc_constraints: []
                })
            }
        },
        _ => {}
    }

    // Inject Self into type_param_scope so Self::Item resolves
    ctx.type_param_scope.insert("Self", self_var)

    // Inject associated types into qualified_assoc_scope for Self::Item paths
    match ctx.env.trait_reg.traits.get(trait_name) {
        some(tdef) => {
            for atdef in tdef.assoc_types {
                // Associated types are already in type_param_scope (bare name, e.g. "Item")
                // from register_trait. Now also inject Self::Item qualified path.
                match ctx.type_param_scope.get(atdef.name) {
                    some(at_ty) => {
                        ctx.qualified_assoc_scope.insert("Self::${atdef.name}", at_ty)
                    },
                    none => {}
                }
            }
        },
        none => {}
    }

    for p in hparams {
        let exact_trait_def_id = match p.def_id {
            some(id) => id,
            none => panic(
                "unreachable: trait default parameter has no exact DefId")
        }
        ctx.env.bind(p.name, TypeScheme {
            ty: p.ty, type_vars: [], bounds: [],
            def_id: some(exact_trait_def_id)
        })
        if p.is_mutable {
            match ctx.env.lookup(p.name) {
                some(ps) => match ps.def_id {
                    some(did) => { ctx.env.scope.mutable_vars.insert(did) },
                    none => {}
                },
                none => {}
            }
        }
    }

    let body_result = some(infer_block(ctx, body, none)) catch { _ => none }

    let final_body = match body_result {
        some(br) => {
            ctx.subst = br.subst
            let body_type = apply_subst(ctx.subst, hexpr_type(br.hexpr))
            match body_type {
                Type::NeverType => {},
                _ => {
                    // A terminal return statement has already constrained
                    // method_return while infer_stmt handled its value.  The
                    // enclosing no-tail block is represented as Unit, not as
                    // a second value-producing return path.
                    if !block_ends_with_return_statement(br.hexpr) {
                        let return_notes: List<DiagnosticNote> = [
                            DiagnosticNote {
                                message: "trait method return type is '${type_to_string(apply_subst(ctx.subst, method_return))}'",
                                span: none
                            },
                            DiagnosticNote {
                                message: "trait default body evaluates to '${type_to_string(body_type)}'",
                                span: some(hexpr_span(br.hexpr))
                            }
                        ]
                        ctx.subst = unify_at_noted(
                            ctx.sink, ctx.env, hexpr_type(br.hexpr),
                            method_return, ctx.subst,
                            hexpr_span(br.hexpr), return_notes)
                    }
                }
            }
            // Trait defaults own the same declared-effect constraint surface
            // as ordinary functions.  Payloads can be the only source for a
            // pending call's hidden type parameter, so thread the resulting
            // substitution before callable shadows and owner drain.
            let (_, constrained_subst) = constrain_declared_fn_effects(
                ctx, method_identity, br.effects, method_effects,
                method_span, ctx.subst)
            ctx.subst = constrained_subst
            register_bounded_callable_value_shadows(
                ctx, br.hexpr, ctx.subst)
            drain_pending_dicts(ctx, obligation_checkpoint, ctx.subst)
            let zctx = ZonkCtx {
                subst: ctx.subst, names: map_new(),
                dict_resolver: some(ctx)
            }
            let result = some(zonk_block(zctx, br.hexpr))
            ctx.subst = saved_subst
            result
        },
        none => {
            rollback_pending_dicts(ctx, obligation_checkpoint)
            ctx.subst = saved_subst
            none
        }
    }
    // Keep the trait's Self/supertrait bounds and parameter scope alive
    // through value-zonk so bounded function values can capture them.
    ctx.current_fn_return_type = saved_fn_return
    ctx.env.pop_scope()
    ctx.current_fn_bounds = match ctx.fn_bounds_stack.pop() { some(prev) => prev, none => [] }
    ctx.type_param_scope = saved_tp_scope
    ctx.qualified_assoc_scope = saved_qualified_assoc
    assert_pending_dict_owner_closed(ctx, obligation_checkpoint)
    final_body
}

fn check_extern_fn_decl(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, params: List<Param>, declared_effects: List<EffectExpr>?, is_pub: Bool, span: Span) -> HDecl {
    let scheme = match ctx.env.lookup(name) {
        some(s) => s,
        none => {
            let _ = type_error(ctx.sink, E0201, "extern fn not found: ${name}", span,
                DiagnosticContext::OtherContext { detail: some("extern fn '${name}' was not registered") })
            fail.raise(CompileError {})
        }
    }
    let fn_params: List<Type> = match scheme.ty {
        Type::FnType { params: fps, .. } => fps,
        _ => []
    }
    let fn_ret = match scheme.ty {
        Type::FnType { return_type, .. } => return_type,
        _ => UNIT
    }
    let mut hparams: List<HParam> = []
    let mut i = 0
    for p in params {
        let ptype = match fn_params.get(i) { some(t) => t, none => UNIT }
        // Preserve the declared mutability as project-link metadata. Genuine
        // FFI marshalling ignores this field, while an exact internal extern
        // forward must distinguish `mut T` from `T`.
        hparams.push(HParam { name: p.name, ty: ptype, def_id: none, is_mutable: p.is_mutable })
        i = i + 1
    }
    let extern_effects = match declared_effects {
        some(de) => resolve_declared_effects(ctx, de),
        none => EMPTY_ROW
    }
    HDecl::ExternFn {
        name: name, abi_name: extern_abi_leaf(name),
        def_id: scheme.def_id, type_params: type_params,
        params: hparams, return_type: fn_ret, effects: extern_effects,
        is_pub: is_pub, span: span
    }
}

struct FnBodyResult {
    params: List<HParam>,
    ret: Type,
    eff: EffectRow,
    body: HExpr
}

// Statement-form `return value` constrains current_fn_return_type directly,
// while a no-tail block is still represented as Unit.  Distinguish that
// terminal control transfer from a genuinely Unit-valued function body.
fn block_ends_with_return_statement(body: HExpr) -> Bool {
    match body {
        HExpr::Block { stmts, tail, .. } => {
            if tail.is_some() { return false }
            let mut terminal_return = false
            for stmt in stmts {
                terminal_return = match stmt {
                    HStmt::Return { .. } => true,
                    _ => false
                }
            }
            terminal_return
        },
        _ => false
    }
}

// Declared effects are part of the function owner's constraint surface, not a
// post-zonk API check.  Their payload types can be the only source that fixes
// a pending call's hidden type arguments, so apply them before owner drain.
fn constrain_declared_fn_effects(
    mut ctx: InferCtx, fn_name: Str,
    inferred_effects: EffectRow, declared_row: EffectRow, span: Span,
    subst: UnionFind
) -> (EffectRow, UnionFind) {
    let mut s = subst
    for inferred_eff in inferred_effects.effects {
        let mut found = false
        for declared_eff in declared_row.effects {
            if effects_match_kind(inferred_eff, declared_eff) {
                found = true
                match (inferred_eff, declared_eff) {
                    (Effect::FailEffect { error_type: ie },
                     Effect::FailEffect { error_type: de }) => {
                        s = unify_at(
                            ctx.sink, ctx.env, ie, de, s, span)
                    },
                    (Effect::MutEffect { state_type: is },
                     Effect::MutEffect { state_type: ds }) => {
                        s = unify_at(
                            ctx.sink, ctx.env, is, ds, s, span)
                    },
                    (Effect::CustomEffect { type_args: ia, .. },
                     Effect::CustomEffect { type_args: da, .. }) => {
                        let mut i = 0
                        while i < ia.len() && i < da.len() {
                            s = unify_at(
                                ctx.sink, ctx.env,
                                ia.get(i).unwrap_or(UNIT),
                                da.get(i).unwrap_or(UNIT),
                                s, span)
                            i = i + 1
                        }
                    },
                    _ => {}
                }
            }
        }
        if !found {
            let fn_display = nominal_display_name(fn_name)
            let _ = type_error(ctx.sink, E0404,
                "Function '${fn_display}' has undeclared effect: ${effect_to_string(inferred_eff)}",
                span,
                DiagnosticContext::OtherContext {
                    detail: some("effect annotation violation")
                })
        }
    }
    (declared_row, s)
}

fn check_fn_body(
    mut ctx: InferCtx,
    fn_name: Str,
    registration_scheme: TypeScheme?,
    type_params: List<TypeParam>,
    hparams: List<HParam>,
    expected_ret: Type,
    declared_effects: EffectRow?,
    body: Expr,
    saved_tp_scope: Map<Str, Type>,
    span: Span,
    obligation_checkpoint: Int
) -> FnBodyResult {
    let body_result = infer_block(ctx, body, some(ctx.subst))
    ctx.subst = body_result.subst
    // Skip body-vs-return unification when the body type is Never (bottom).
    // Never is compatible with any type, but unify(Never, ?T) would bind ?T = Never,
    // contaminating the return type.  With B-122 rebind_fn_type this turns the
    // scheme's return type into Never, so all callers see the function as diverging.
    // Functions whose body ends with fail.raise / panic still have correct return
    // types from their `return` statements (which unify with expected_ret directly).
    let body_type_resolved = apply_subst(ctx.subst, hexpr_type(body_result.hexpr))
    match body_type_resolved {
        Type::NeverType => {},
        _ => {
            if !block_ends_with_return_statement(body_result.hexpr) {
                let fn_body_notes: List<DiagnosticNote> = [
                    DiagnosticNote { message: "function return type is declared as '${type_to_string(apply_subst(ctx.subst, expected_ret))}'", span: some(span) },
                    DiagnosticNote { message: "function body evaluates to '${type_to_string(apply_subst(ctx.subst, hexpr_type(body_result.hexpr)))}'", span: some(hexpr_span(body_result.hexpr)) }
                ]
                ctx.subst = unify_at_noted(ctx.sink, ctx.env, hexpr_type(body_result.hexpr), expected_ret, ctx.subst, span, fn_body_notes)
            }
        },
    }

    let owner_effects = match declared_effects {
        some(declared_row) => {
            let constrained = constrain_declared_fn_effects(
                ctx, fn_name, body_result.effects, declared_row, span,
                ctx.subst)
            ctx.subst = constrained.1
            constrained.0
        },
        none => body_result.effects
    }

    register_bounded_callable_value_shadows(
        ctx, body_result.hexpr, ctx.subst)

    // Defaults and the body share this function owner's inference variables.
    // Return/annotation/arm/effect constraints are now complete; settle every
    // call slot before zonk or restoration can detach those variables.
    drain_pending_dicts(ctx, obligation_checkpoint, ctx.subst)

    let mut local_names: Map<Int, Str> = map_new()
    for tp in type_params {
        match ctx.type_param_scope.get(tp.name) {
            some(tv) => match tv {
                Type::TypeVar { .. } => {
                    let resolved = apply_subst(ctx.subst, tv)
                    match resolved { Type::TypeVar { id: rid, .. } => { local_names.insert(rid, tp.name) }, _ => {} }
                },
                _ => {}
            },
            none => {}
        }
    }
    let mut declared_names: Set<Str> = set_new()
    for tp in type_params { declared_names.insert(tp.name) }
    let mut sorted_tp_scope2 = ctx.type_param_scope.entries()
    sorted_tp_scope2.sort_by(compare_by_first)
    for entry in sorted_tp_scope2 {
        let (tpname, tv) = entry
        if !saved_tp_scope.contains_key(tpname) && !declared_names.contains(tpname) {
            match tv {
                Type::TypeVar { .. } => {
                    let resolved = apply_subst(ctx.subst, tv)
                    match resolved { Type::TypeVar { id: rid, .. } => { local_names.insert(rid, tpname) }, _ => {} }
                },
                _ => {}
            }
        }
    }

    // Add associated type variable names from trait bounds so error messages
    // show "Item" instead of "?NNN" for associated types
    let mut seen_traits: Set<Str> = set_new()
    for fb in ctx.current_fn_bounds {
        if seen_traits.contains(fb.trait_name) { continue }
        seen_traits.insert(fb.trait_name)
        match ctx.env.trait_reg.traits.get(fb.trait_name) {
            some(tdef) => {
                for atdef in tdef.assoc_types {
                    if !local_names.contains_key(atdef.var_id) {
                        let resolved = apply_subst(ctx.subst, Type::TypeVar { id: atdef.var_id, name: none })
                        match resolved { Type::TypeVar { id: rid, .. } => { local_names.insert(rid, atdef.name) }, _ => {} }
                    }
                }
            },
            none => {}
        }
    }

    let zctx = ZonkCtx {
        subst: ctx.subst, names: local_names,
        dict_resolver: some(ctx)
    }
    let mut final_params: List<HParam> = []
    for hp in hparams { final_params.push(zonk_param(zctx, hp)) }
    let final_ret = zonk_type(zctx, expected_ret)
    let eff = zonk_row(zctx, owner_effects)
    let final_body = zonk_block(zctx, body_result.hexpr)
    match registration_scheme {
        some(scheme) => capture_assoc_rebind_provenance(
            ctx, fn_name, scheme, final_params, final_ret, eff, ctx.subst
        ),
        none => {}
    }
    FnBodyResult { params: final_params, ret: final_ret, eff: eff, body: final_body }
}

// Capture the owner-qualified identity of check-time associated-type variables
// while the function's transient scopes are still live. rebind_fn_type runs
// after check_fn_decl returns, when qualified_assoc_scope/current_fn_bounds have
// already been restored, so it cannot reconstruct this safely from a bare
// TypeVar id.
fn capture_assoc_rebind_provenance(
    mut ctx: InferCtx,
    fn_name: Str,
    registration_scheme: TypeScheme,
    checked_params: List<HParam>,
    checked_return: Type,
    checked_effects: EffectRow,
    final_subst: UnionFind
) {
    let mut captured: List<AssocRebindEntry> = []
    match registration_scheme.ty {
        Type::FnType {
            params: registration_params,
            return_type: registration_return,
            effects: registration_effects
        } => {
            // First map each check-time owner (T/U/...) back to the corresponding
            // registration-time owner using the ordinary function shape.
            let mut owner_mapping: Map<Int, Type> = map_new()
            let mut owner_conflicts: Set<Int> = set_new()
            let mut param_index = 0
            for checked_param in checked_params {
                match registration_params.get(param_index) {
                    some(registration_param) =>
                        build_var_mapping(
                            checked_param.ty, registration_param,
                            owner_mapping, owner_conflicts
                        ),
                    none => {}
                }
                param_index = param_index + 1
            }
            build_var_mapping(
                checked_return, registration_return,
                owner_mapping, owner_conflicts
            )
            build_effect_var_mapping(
                checked_effects, registration_effects,
                owner_mapping, owner_conflicts
            )

            for fn_bound in ctx.current_fn_bounds {
                let checked_owner = apply_subst(
                    final_subst,
                    Type::TypeVar {
                        id: fn_bound.type_param_var_id,
                        name: some(fn_bound.type_param_name)
                    }
                )
                let registration_owner_id = match checked_owner {
                    Type::TypeVar { id: checked_owner_id, .. } => {
                        if owner_conflicts.contains(checked_owner_id) {
                            none
                        } else {
                            let registration_owner = apply_subst_map(
                                owner_mapping, checked_owner
                            )
                            match registration_owner {
                                Type::TypeVar { id, .. } => some(id),
                                _ => none
                            }
                        }
                    },
                    _ => none
                }

                match ctx.env.trait_reg.traits.get(fn_bound.trait_name) {
                    some(trait_def) => {
                        for assoc_def in trait_def.assoc_types {
                            let origin = "${fn_bound.type_param_name}::${assoc_def.name}"
                            match ctx.qualified_assoc_scope.get(origin) {
                                some(checked_assoc) => {
                                    let zonked_assoc = apply_subst(
                                        final_subst, checked_assoc
                                    )
                                    let mut found_target = false
                                    match registration_owner_id {
                                        some(owner_id) => {
                                            for scheme_bound in registration_scheme.bounds {
                                                if scheme_bound.type_var == owner_id &&
                                                   scheme_bound.trait_name == fn_bound.trait_name {
                                                    for constraint in scheme_bound.assoc_constraints {
                                                        if constraint.name == assoc_def.name {
                                                            found_target = true
                                                            captured.push(AssocRebindEntry {
                                                                check_type: zonked_assoc,
                                                                registration_type: some(constraint.ty),
                                                                owner_name: fn_bound.type_param_name,
                                                                trait_name: fn_bound.trait_name,
                                                                assoc_name: assoc_def.name
                                                            })
                                                        }
                                                    }
                                                }
                                            }
                                        },
                                        none => {}
                                    }
                                    // Impl method cores are deliberately
                                    // boundless. Their registration predicate
                                    // authority is current_fn_bounds, materialized
                                    // from the exact owning ImplEntry above.
                                    if !found_target &&
                                       registration_scheme.bounds.len() == 0 {
                                        for constraint in fn_bound.assoc_constraints {
                                            if constraint.name == assoc_def.name {
                                                found_target = true
                                                captured.push(AssocRebindEntry {
                                                    check_type: zonked_assoc,
                                                    registration_type: some(constraint.ty),
                                                    owner_name: fn_bound.type_param_name,
                                                    trait_name: fn_bound.trait_name,
                                                    assoc_name: assoc_def.name
                                                })
                                            }
                                        }
                                    }
                                    if !found_target {
                                        captured.push(AssocRebindEntry {
                                            check_type: zonked_assoc,
                                            registration_type: none,
                                            owner_name: fn_bound.type_param_name,
                                            trait_name: fn_bound.trait_name,
                                            assoc_name: assoc_def.name
                                        })
                                    }
                                },
                                none => {}
                            }
                        }
                    },
                    none => {}
                }
            }
        },
        _ => {}
    }
    ctx.rebind_assoc_provenance.insert(fn_name, captured)
}

fn check_fn_decl(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    params: List<Param>, return_type: TypeExpr?,
    declared_effects: List<EffectExpr>?, body: Expr,
    is_pub: Bool, span: Span, self_type: Type?,
    registration_override: TypeScheme?, rebind_identity: Str?
) -> HDecl {
    let obligation_checkpoint = pending_dict_checkpoint(ctx)
    let result = some(check_fn_decl_transaction(
        ctx, name, type_params, params, return_type,
        declared_effects, body, is_pub, span, self_type,
        registration_override, rebind_identity,
        obligation_checkpoint)) catch { _ => none }
    match result {
        some(hdecl) => {
            assert_pending_dict_owner_closed(ctx, obligation_checkpoint)
            hdecl
        },
        none => {
            rollback_pending_dicts(ctx, obligation_checkpoint)
            fail.raise(CompileError {})
        }
    }
}

fn check_fn_decl_transaction(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    params: List<Param>, return_type: TypeExpr?,
    declared_effects: List<EffectExpr>?, body: Expr,
    is_pub: Bool, span: Span, self_type: Type?,
    registration_override: TypeScheme?, rebind_identity: Str?,
    obligation_checkpoint: Int
) -> HDecl {
    // Save the registration scheme before entering the parameter scope: a
    // parameter is allowed to have the same spelling as its function.
    let registration_scheme = match registration_override {
        some(scheme) => some(scheme),
        none => ctx.env.lookup(name)
    }
    let provenance_key = match rebind_identity {
        some(identity) => identity,
        none => name
    }
    // A failed or repeated check must never reuse provenance from an earlier
    // inline/SCC precheck of the same canonical function identity.
    ctx.rebind_assoc_provenance.insert(provenance_key, [])

    let saved_subst = ctx.subst
    ctx.subst = empty_subst()
    ctx.env.push_scope()

    let saved_tp_scope = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    for tp in type_params {
        let tv = ctx.env.fresh_var()
        ctx.type_param_scope.insert(tp.name, tv)
        ctx.env.bind_mono(tp.name, tv)
    }

    ctx.fn_bounds_stack.push(ctx.current_fn_bounds)
    let mut inherited_bounds: List<FnBoundsEntry> = []
    for ib in ctx.current_fn_bounds { inherited_bounds.push(ib) }
    ctx.current_fn_bounds = inherited_bounds
    for tp in type_params {
        match ctx.type_param_scope.get(tp.name) {
            some(tv) => match tv {
                Type::TypeVar { id, .. } => {
                    for bound in tp.bounds {
                        let bound_trait = resolve_trait_identity(ctx, bound.trait_name)
                        let mut assoc_constraints: List<AssocConstraintEntry> = []
                        for constraint in bound.assoc_constraints {
                            assoc_constraints.push(AssocConstraintEntry {
                                name: constraint.name,
                                ty: resolve_type_expr(ctx, constraint.ty)
                            })
                        }
                        ctx.current_fn_bounds.push(FnBoundsEntry {
                            type_param_var_id: id, trait_name: bound_trait,
                            type_param_name: tp.name,
                            assoc_constraints: assoc_constraints
                        })
                        // Expand supertrait bounds: if T: Ord and Ord: Eq, add T: Eq too
                        let supers = collect_all_supertraits(ctx, bound_trait)
                        for st_name in supers {
                            ctx.current_fn_bounds.push(FnBoundsEntry {
                                type_param_var_id: id, trait_name: st_name,
                                type_param_name: tp.name,
                                assoc_constraints: []
                            })
                        }
                    }
                },
                _ => {}
            },
            none => {}
        }
    }

    // Inject associated types from type param bounds into type_param_scope
    // so that zonk names map includes associated type variable names (e.g., Item instead of ?NNN)
    inject_assoc_types_from_bounds(ctx, type_params)

    let mut hparams: List<HParam> = []
    let mut param_types: List<Type> = []
    for p in params {
        let ptype = match p.type_annotation {
            some(ta) => resolve_type_expr(ctx, ta),
            none => {
                if p.name == "self" {
                    match self_type { some(st) => st, none => ctx.env.fresh_var() }
                } else {
                    ctx.env.fresh_var()
                }
            }
        }
        ctx.env.bind_mono(p.name, ptype)
        let param_scheme = ctx.env.lookup(p.name)
        match param_scheme {
            some(ps) => {
                match ps.def_id {
                    some(did) => {
                        ctx.env.record_def_span(did, p.span)
                        ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                        if p.is_mutable {
                            ctx.env.scope.mutable_vars.insert(did)
                            ctx.env.scope.mut_param_defs.insert(did)
                            // Auto-box mut value-type parameters (not self)
                            if p.name != "self" {
                                let resolved_pt = apply_subst(ctx.subst, ptype)
                                if is_value_type(resolved_pt) {
                                    ctx.boxed_vars.insert(did)
                                }
                            }
                        } else {
                            ctx.env.scope.let_defs.insert(did)
                        }
                    },
                    none => {}
                }
                hparams.push(HParam { name: p.name, ty: ptype, def_id: ps.def_id, is_mutable: p.is_mutable })
            },
            none => hparams.push(HParam { name: p.name, ty: ptype, def_id: none, is_mutable: p.is_mutable })
        }
        param_types.push(ptype)
    }

    let saved_fn_return = ctx.current_fn_return_type
    let expected_ret = match return_type {
        some(rt) => resolve_type_expr(ctx, rt),
        none => ctx.env.fresh_var()
    }
    ctx.current_fn_return_type = some(expected_ret)
    // Resolve while this owner's type-parameter and associated-type scopes
    // are live.  check_fn_body applies the payload constraints before drain.
    let owner_declared_effects = match declared_effects {
        some(de) => some(resolve_declared_effects(ctx, de)),
        none => none
    }

    let try_result = some(
        check_fn_body(
            ctx, provenance_key, registration_scheme, type_params, hparams,
            expected_ret, owner_declared_effects,
            body, saved_tp_scope, span,
            obligation_checkpoint
        )
    ) catch { _ => none }

    // Save complete bounds (inherited + own) before pop
    let complete_fn_bounds = ctx.current_fn_bounds

    // Cleanup
    ctx.current_fn_return_type = saved_fn_return
    ctx.env.pop_scope()
    ctx.type_param_scope = saved_tp_scope
    ctx.qualified_assoc_scope = saved_qualified_assoc
    ctx.current_fn_bounds = match ctx.fn_bounds_stack.pop() { some(prev) => prev, none => [] }
    ctx.subst = saved_subst

    let fn_result = match try_result {
        some(r) => r,
        none => fail.raise(CompileError {})
    }
    let final_params = fn_result.params
    let final_ret = fn_result.ret
    let final_effects = fn_result.eff
    let final_body = fn_result.body

    // Check: main function must not have unhandled custom effects.
    // io/fail/mut are allowed (io is implicit, fail has default handler, mut is Cell-based),
    // but CustomEffect requires an explicit handler and cannot propagate past main.
    // Exception: effects where all ops have default handlers are allowed (auto-injected evidence).
    if name == "main" || name.ends_with("$$_main") {
        for eff in final_effects.effects {
            match eff {
                Effect::CustomEffect { name: eff_name, .. } => {
                    let mut skip = false
                    match ctx.env.types.effects.get(eff_name) {
                        some(edef) => {
                            if edef.all_have_defaults { skip = true }
                        },
                        none => {}
                    }
                    if !skip {
                        let effect_display = nominal_display_name(eff_name)
                        let effect_notes: List<DiagnosticNote> = [
                            DiagnosticNote { message: "effect '${effect_display}' is used but not handled in main", span: some(span) },
                            DiagnosticNote { message: "use 'handle ... with { ${effect_display} { op_name(args) => result } }' to handle this effect", span: none }
                        ]
                        let _ = type_error_with_notes(ctx.sink, E0403,
                            "Unhandled effect '${effect_display}' in main function; custom effects must be handled before reaching main",
                            span,
                            DiagnosticContext::EffectUnhandled { eff: effect_display, in_function: some("main") },
                            effect_notes)
                    }
                },
                _ => {}
            }
        }
    }

    let mut trait_bounds: List<TraitBound> = []
    for fb in complete_fn_bounds {
        trait_bounds.push(TraitBound { type_param: fb.type_param_name, trait_name: fb.trait_name })
    }

    let fn_def_id = match registration_scheme {
        some(scheme) => scheme.def_id,
        none => none
    }
    match fn_def_id {
        some(did) => ctx.env.record_def_span(did, span),
        none => {}
    }

    // Register fn_mut_params for call-site pre-boxing analysis
    // Only flag params that are mut AND value-type (Int/Float/Bool/Str).
    // self params and reference-type params are never boxed.
    let mut mut_flags: List<Bool> = []
    let mut fi = 0
    for p in params {
        if p.name == "self" || !p.is_mutable {
            mut_flags.push(false)
        } else {
            // Check if the param's resolved type is a value type
            match final_params.get(fi) {
                some(fp) => mut_flags.push(is_value_type(fp.ty)),
                none => mut_flags.push(false)
            }
        }
        fi = fi + 1
    }
    ctx.fn_mut_params.insert(name, mut_flags)

    HDecl::Fn {
        name: name, def_id: fn_def_id, type_params: type_params,
        params: final_params, return_type: final_ret, effects: final_effects,
        body: final_body, is_pub: is_pub, trait_bounds: trait_bounds, span: span
    }
}

fn check_test_decl(mut ctx: InferCtx, description: Str, body: Expr, span: Span) -> HDecl {
    let obligation_checkpoint = pending_dict_checkpoint(ctx)
    let saved_subst = ctx.subst
    ctx.subst = empty_subst()
    ctx.env.push_scope()
    let body_result = some(infer_block(ctx, body, none)) catch { _ => none }

    let final_body = match body_result {
        some(br) => {
            ctx.subst = br.subst
            register_bounded_callable_value_shadows(
                ctx, br.hexpr, ctx.subst)
            drain_pending_dicts(ctx, obligation_checkpoint, ctx.subst)
            let zctx = ZonkCtx {
                subst: ctx.subst, names: map_new(),
                dict_resolver: some(ctx)
            }
            let result = zonk_block(zctx, br.hexpr)
            ctx.subst = saved_subst
            result
        },
        none => {
            rollback_pending_dicts(ctx, obligation_checkpoint)
            ctx.subst = saved_subst
            // The scope must be restored before re-raising the declaration
            // error; the success path pops once below after value-zonk.
            ctx.env.pop_scope()
            fail.raise(CompileError {})
        }
    }
    ctx.env.pop_scope()

    HDecl::Test { description: description, body: final_body, span: span }
}

// ============================================================
// Public entry point
// ============================================================

fn check_one_decl(
    mut ctx: InferCtx, decl: Decl, frame_decl_index: Int?,
    mut hdecls: List<HDecl>
) {
    let hd = check_decl(ctx, decl, frame_decl_index)

    // Update fn effects before push (modifies ctx.env, not hdecls)
    match hd {
        HDecl::Fn { name, effects, .. } => {
            if effects.effects.len() > 0 {
                update_fn_effects(ctx.env, name, effects)
            }
        },
        _ => {}
    }

    // Expand delegates first, collect results before pushing anything to hdecls.
    // If expand_delegate_impls fails (raises CompileError), neither the impl HIR
    // nor partial delegate HIR will be left in hdecls.
    let mut delegate_decls: List<HDecl> = []
    match decl {
        Decl::Impl { target_type, type_params, methods, span, .. } => {
            for source_member_index in 0..methods.len() {
                match methods.get(source_member_index) {
                    some(Decl::Delegate { field, span: dspan, .. }) => {
                        let delegate_impls = expand_delegate_impls(
                            ctx, hd, source_member_index, field, dspan)
                        for di in delegate_impls { delegate_decls.push(di) }
                    },
                    _ => {}
                }
            }
        },
        _ => {}
    }

    // Only push after everything succeeded
    hdecls.push(hd)
    for di in delegate_decls { hdecls.push(di) }
}

// B-122: Check a declaration and rebind fn/impl-method types with resolved types.
// After check_fn_decl, the registered type scheme still has unresolved fresh vars
// from Pass 1. Rebinding replaces it with the fully-resolved type from inference,
// so that subsequent callers (in SCC topological order) see correct return types.
fn check_one_decl_with_rebind(
    mut ctx: InferCtx, decl: Decl, frame_decl_index: Int?,
    mut hdecls: List<HDecl>
) {
    let hd = check_decl(ctx, decl, frame_decl_index)

    // Update fn effects and rebind resolved types
    match hd {
        HDecl::Fn { name, params, return_type, effects, span, .. } => {
            // update_fn_effects installs check-time effect variables into the
            // live scheme.  Snapshot the authoritative registration identity
            // first so effect-only type parameters still map back to the same
            // variables owned by type_vars / SchemeBounds during rebind.
            let registration_scheme = ctx.env.lookup(name)
            if effects.effects.len() > 0 {
                update_fn_effects(ctx.env, name, effects)
            }
            // B-122: Rebind with fully-resolved type from inference
            rebind_fn_type(
                ctx, name, params, return_type, effects, span,
                registration_scheme)
        },
        // Impl methods are rebound against their exact ImplEntry schemes in
        // check_impl_decl_canonical; a bare method spelling is not an identity.
        HDecl::Impl { .. } => {},
        _ => {}
    }

    // Delegate expansion (same as check_one_decl)
    let mut delegate_decls: List<HDecl> = []
    match decl {
        Decl::Impl { target_type, type_params, methods, span, .. } => {
            for source_member_index in 0..methods.len() {
                match methods.get(source_member_index) {
                    some(Decl::Delegate { field, span: dspan, .. }) => {
                        let delegate_impls = expand_delegate_impls(
                            ctx, hd, source_member_index, field, dspan)
                        for di in delegate_impls { delegate_decls.push(di) }
                    },
                    _ => {}
                }
            }
        },
        _ => {}
    }

    hdecls.push(hd)
    for di in delegate_decls { hdecls.push(di) }
}

// Locate one inline function by its exact canonical SCC node and pre-check it
// in the same module context used by the final HIR pass.  This lets recursive
// call-graph ordering cross ModBlock boundaries without flattening the emitted
// HIR or losing self/super import resolution.
fn precheck_inline_fn_in_mod_body(
    mut ctx: InferCtx,
    mod_name: Str,
    uses: List<UseDecl>,
    decls: List<Decl>,
    required_effects: List<EffectExpr>?,
    target_name: Str,
    project_frame_active: Bool
) -> Bool {
    if !project_frame_active {
        insert_mod_aliases(ctx, mod_name, decls, false)
        resolve_mod_uses(ctx, uses, true)
    }
    match required_effects {
        some(req_effs) => {
            let cap = resolve_declared_effects(ctx, req_effs)
            ctx.mod_unsafe_allowed = cap.effects.any(fn(e) {
                match e { Effect::UnsafeEffect => true, _ => false }
            })
        },
        none => { ctx.mod_unsafe_allowed = false }
    }

    let mut found = false
    for decl_index in 0..decls.len() {
        let decl = decls.get(decl_index).unwrap()
        let prefixed = prefix_decl_name(mod_name, decl)
        match prefixed {
            Decl::Fn { name, .. } => {
                if name == target_name {
                    let mut discarded: List<HDecl> = []
                    let result = some(check_one_decl_with_rebind(
                        ctx, prefixed, some(decl_index),
                        discarded)) catch { _ => none }
                    found = true
                }
            },
            Decl::ModBlock { name, uses: nested_uses, decls: nested_decls, required_effects: nested_required, .. } => {
                if !found && precheck_inline_fn_in_mod(
                    ctx, name, nested_uses, nested_decls,
                    nested_required, target_name, decl_index) {
                    found = true
                }
            },
            _ => {}
        }
        if found { break }
    }
    found
}

fn precheck_inline_fn_in_mod(
    mut ctx: InferCtx,
    mod_name: Str,
    uses: List<UseDecl>,
    decls: List<Decl>,
    required_effects: List<EffectExpr>?,
    target_name: Str,
    frame_decl_index: Int
) -> Bool {
    let project_active = ctx.project_namespace_file_key.is_some()
    let mut entered_project_frame = false
    if project_active {
        entered_project_frame = enter_project_child_frame(
            ctx, frame_decl_index)
        if !entered_project_frame {
            panic("unreachable: resolver plan missing inline precheck frame")
        }
    }
    let segments = mod_name.split("::")
    let simple_name = segments.get(segments.len() - 1).unwrap_or(mod_name)
    ctx.mod_path_stack.push(simple_name)
    let prev_unsafe_allowed = ctx.mod_unsafe_allowed
    let result = precheck_inline_fn_in_mod_body(
        ctx, mod_name, uses, decls, required_effects,
        target_name, project_active) catch { _ => {
            ctx.mod_unsafe_allowed = prev_unsafe_allowed
            let _ = ctx.mod_path_stack.pop()
            if entered_project_frame {
                let _ = exit_project_namespace_frame(ctx)
            }
            fail.raise(CompileError {})
        }
    }
    ctx.mod_unsafe_allowed = prev_unsafe_allowed
    let _ = ctx.mod_path_stack.pop()
    if entered_project_frame {
        let _ = exit_project_namespace_frame(ctx)
    }
    result
}

fn precheck_inline_fn(
    mut ctx: InferCtx, decls: List<Decl>, target_name: Str
) -> Bool {
    for decl_index in 0..decls.len() {
        let decl = decls.get(decl_index).unwrap()
        match decl {
            Decl::ModBlock { name, uses, decls: mod_decls, required_effects, .. } => {
                if precheck_inline_fn_in_mod(
                    ctx, name, uses, mod_decls, required_effects,
                    target_name, decl_index) { return true }
            },
            _ => {}
        }
    }
    false
}

fn collect_impl_scc_fn_names(
    decls: List<Decl>, prefix: Str?, mut names: Set<Str>
) {
    for decl in decls {
        match decl {
            Decl::Impl { methods, .. } => {
                for method in methods {
                    match method {
                        Decl::Fn { name, .. } => {
                            let full_name = match prefix {
                                some(p) => "${p}::${name}",
                                none => name
                            }
                            names.insert(full_name)
                        },
                        _ => {}
                    }
                }
            },
            Decl::ModBlock { name, decls: nested, .. } => {
                let nested_prefix = match prefix {
                    some(p) => "${p}::${name}",
                    none => name
                }
                collect_impl_scc_fn_names(nested, some(nested_prefix), names)
            },
            _ => {}
        }
    }
}

fn inline_dependency_closure(
    graph: Map<Str, List<Str>>, roots: Set<Str>, blocked: Set<Str>
) -> Set<Str> {
    let mut closure: Set<Str> = set_new()
    let mut pending: List<Str> = []
    for root in roots {
        closure.insert(root)
        pending.push(root)
    }
    while pending.len() > 0 {
        match pending.pop() {
            some(node) => match graph.get(node) {
                some(deps) => {
                    for dep in deps {
                        if !blocked.contains(dep) && !dep.starts_with("impl::") && !closure.contains(dep) {
                            closure.insert(dep)
                            pending.push(dep)
                        }
                    }
                },
                none => {}
            },
            none => {}
        }
    }
    closure
}

fn precheck_top_level_fn_at(
    mut ctx: InferCtx, decls: List<Decl>, index: Int
) {
    match decls.get(index) {
        some(decl) => {
            let mut discarded: List<HDecl> = []
            let result = some(check_one_decl_with_rebind(
                ctx, decl, none, discarded)) catch { _ => none }
        },
        none => {}
    }
}

// B-122: Rebind a fn's type scheme with resolved return type and effects.
//
// After check_fn_decl, the registered type scheme may have a free TypeVar for
// the return type (from Pass 1 registration of unannotated returns). This var
// is never bound globally — each caller independently instantiates it, making
// the return type effectively polymorphic (#149).
//
// We fix this by replacing the scheme's return type with the concrete resolved
// type from inference. For polymorphic fns where the resolved return type still
// contains TypeVars (e.g., generic identity fn), we build a mapping from
// check-time var ids to registration-time var ids using param correspondence,
// so the scheme remains consistent.
// A checked function can have its canonical value binding plus source-spelled,
// inline-published, and consumer aliases. File-module canonical names contain
// `$$_`, while single-file inline names do not, so exact origin — never the
// spelling shape — is the selection criterion. Every alias
// deliberately has its own lexical DefId, whose recorded origin is flattened
// to the canonical binding. Refresh every exact-origin alias together with the
// canonical scheme; otherwise a pub-use chain can keep the registration-time
// EMPTY_ROW / unresolved return variables. Each fresh alias DefId must survive
// the refresh so local shadowing and provenance remain lexical.
fn rebind_fn_scheme_with_alias(mut ctx: InferCtx, name: Str, scheme: TypeScheme) {
    ctx.env.rebind(name, scheme)

    // Update the map entry in its owning scope rather than calling
    // TypeEnv.rebind(alias_name): two lexical scopes may contain the same
    // spelling, and only the DefId whose exact origin is `name` may change.
    for scope in ctx.env.scope.scopes {
        let mut aliases = scope.variables.entries()
        aliases.sort_by(compare_by_first)
        for entry in aliases {
            let (alias_name, alias_scheme) = entry
            match alias_scheme.def_id {
                some(alias_id) => match ctx.use_aliases.get(alias_id) {
                    some(origin) => {
                        if origin == name {
                            scope.variables.insert(alias_name, TypeScheme {
                                ty: scheme.ty,
                                type_vars: scheme.type_vars,
                                bounds: scheme.bounds,
                                def_id: alias_scheme.def_id
                            })
                        }
                    },
                    none => {}
                },
                none => {}
            }
        }
    }
}

fn type_contains_fn(ty: Type) -> Bool {
    match ty {
        Type::FnType { .. } => true,
        Type::StructType { type_params, .. } => {
            for tp in type_params {
                if type_contains_fn(tp) { return true }
            }
            false
        },
        Type::EnumType { type_params, .. } => {
            for tp in type_params {
                if type_contains_fn(tp) { return true }
            }
            false
        },
        Type::GenericType { base, args } => {
            if type_contains_fn(base) { return true }
            for arg in args {
                if type_contains_fn(arg) { return true }
            }
            false
        },
        Type::RecordType { fields, .. } => {
            for field in fields {
                if type_contains_fn(field.ty) { return true }
            }
            false
        },
        Type::EffectRowType { effects, .. } => {
            for eff in effects {
                match eff {
                    Effect::FailEffect { error_type } => {
                        if type_contains_fn(error_type) { return true }
                    },
                    Effect::MutEffect { state_type } => {
                        if type_contains_fn(state_type) { return true }
                    },
                    Effect::CustomEffect { type_args, .. } => {
                        for arg in type_args {
                            if type_contains_fn(arg) { return true }
                        }
                    },
                    _ => {}
                }
            }
            false
        },
        Type::TupleType { elements } => {
            for element in elements {
                if type_contains_fn(element) { return true }
            }
            false
        },
        Type::PtrType { pointee } => type_contains_fn(pointee),
        _ => false
    }
}

fn report_rebind_shape_mismatch(
    mut ctx: InferCtx, fn_name: Str, reg_ty: Type, check_ty: Type, span: Span
) {
    let display = nominal_display_name(fn_name)
    let expected = type_to_string(reg_ty)
    let actual = type_to_string(check_ty)
    let _ = type_error(ctx.sink, E0301,
        "Cannot safely rebind higher-order parameter in '${display}': registered shape '${expected}' does not match inferred shape '${actual}'",
        span,
        DiagnosticContext::TypeMismatch {
            expected: expected, actual: actual,
            expression: some("higher-order parameter rebind")
        })
}

// A check-time variable is safe to write into a scheme only when the existing
// positional mapping takes it back to a variable already owned by that scheme
// (or to a concrete type). Named variables and variables carrying var_bounds
// may denote declared generics/associated types; generalizing them as a fresh
// anonymous fail payload would discard their bound provenance.
fn audit_fail_payload_var(
    mut ctx: InferCtx,
    fn_name: Str,
    id: Int,
    var_name: Str?,
    mapping: Map<Int, Type>,
    original_scheme_vars: Set<Int>,
    mut unsafe_vars: Set<Int>,
    mut diagnosed_vars: Set<Int>,
    span: Span
) {
    // Conflicted or ownerless associated-type provenance is pre-seeded by
    // rebind_fn_type. Reject it only if it is about to escape through a newly
    // written fail payload; unrelated associated types remain untouched.
    if unsafe_vars.contains(id) {
        if !diagnosed_vars.contains(id) {
            diagnosed_vars.insert(id)
            let display = nominal_display_name(fn_name)
            let detail = "owner-qualified associated type has no unique registration-time target"
            let _ = type_error(ctx.sink, E0503,
                "Cannot rebind fail payload in '${display}': ${detail}",
                span,
                DiagnosticContext::TraitError { detail: detail })
        }
        return
    }

    let mapped = apply_subst_map(mapping, Type::TypeVar { id: id, name: var_name })
    let mut mapped_vars: Set<Int> = set_new()
    collect_free_vars(mapped, mapped_vars)
    let mut new_vars: List<Int> = []
    for mapped_id in mapped_vars {
        if !original_scheme_vars.contains(mapped_id) {
            new_vars.push(mapped_id)
        }
    }
    if new_vars.len() == 0 { return }

    let check_name = match var_name {
        some(n) => n,
        none => ""
    }
    let mut trait_names: Set<Str> = set_new()
    match ctx.env.scope.var_bounds.get(id) {
        some(bounds) => {
            for trait_name in bounds { trait_names.insert(trait_name) }
        },
        none => {}
    }
    for mapped_id in new_vars {
        match ctx.env.scope.var_bounds.get(mapped_id) {
            some(bounds) => {
                for trait_name in bounds { trait_names.insert(trait_name) }
            },
            none => {}
        }
    }
    if check_name == "" && trait_names.len() == 0 { return }

    unsafe_vars.insert(id)
    for mapped_id in new_vars { unsafe_vars.insert(mapped_id) }
    if diagnosed_vars.contains(id) { return }
    diagnosed_vars.insert(id)
    for mapped_id in new_vars { diagnosed_vars.insert(mapped_id) }

    let display = nominal_display_name(fn_name)
    let mut sorted_traits = trait_names.to_list()
    sorted_traits.sort()
    let traits_display = sorted_traits.join(", ")
    let detail = if check_name != "" && sorted_traits.len() > 0 {
        "named check-time variable '${check_name}' has untracked obligations: ${traits_display}"
    } else if check_name != "" {
        "named check-time variable '${check_name}' has no registration-time provenance"
    } else {
        "check-time variable has untracked obligations: ${traits_display}"
    }
    let _ = type_error(ctx.sink, E0503,
        "Cannot rebind fail payload in '${display}': ${detail}",
        span,
        DiagnosticContext::TraitError { detail: detail })
}

fn audit_fail_payload_type(
    mut ctx: InferCtx,
    fn_name: Str,
    ty: Type,
    mapping: Map<Int, Type>,
    original_scheme_vars: Set<Int>,
    mut unsafe_vars: Set<Int>,
    mut diagnosed_vars: Set<Int>,
    span: Span
) {
    match ty {
        Type::TypeVar { id, name } =>
            audit_fail_payload_var(
                ctx, fn_name, id, name, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            ),
        Type::FnType { params, return_type, effects } => {
            for param in params {
                audit_fail_payload_type(
                    ctx, fn_name, param, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
            audit_fail_payload_type(
                ctx, fn_name, return_type, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            )
            for eff in effects.effects {
                match eff {
                    Effect::FailEffect { error_type } =>
                        audit_fail_payload_type(
                            ctx, fn_name, error_type, mapping, original_scheme_vars,
                            unsafe_vars, diagnosed_vars, span
                        ),
                    Effect::MutEffect { state_type } =>
                        audit_fail_payload_type(
                            ctx, fn_name, state_type, mapping, original_scheme_vars,
                            unsafe_vars, diagnosed_vars, span
                        ),
                    Effect::CustomEffect { type_args, .. } => {
                        for arg in type_args {
                            audit_fail_payload_type(
                                ctx, fn_name, arg, mapping, original_scheme_vars,
                                unsafe_vars, diagnosed_vars, span
                            )
                        }
                    },
                    _ => {}
                }
            }
        },
        Type::StructType { type_params, .. } => {
            for tp in type_params {
                audit_fail_payload_type(
                    ctx, fn_name, tp, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::EnumType { type_params, .. } => {
            for tp in type_params {
                audit_fail_payload_type(
                    ctx, fn_name, tp, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::GenericType { base, args } => {
            audit_fail_payload_type(
                ctx, fn_name, base, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            )
            for arg in args {
                audit_fail_payload_type(
                    ctx, fn_name, arg, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::RecordType { fields, .. } => {
            for field in fields {
                audit_fail_payload_type(
                    ctx, fn_name, field.ty, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::EffectRowType { effects, .. } => {
            for eff in effects {
                match eff {
                    Effect::FailEffect { error_type } =>
                        audit_fail_payload_type(
                            ctx, fn_name, error_type, mapping, original_scheme_vars,
                            unsafe_vars, diagnosed_vars, span
                        ),
                    Effect::MutEffect { state_type } =>
                        audit_fail_payload_type(
                            ctx, fn_name, state_type, mapping, original_scheme_vars,
                            unsafe_vars, diagnosed_vars, span
                        ),
                    Effect::CustomEffect { type_args, .. } => {
                        for arg in type_args {
                            audit_fail_payload_type(
                                ctx, fn_name, arg, mapping, original_scheme_vars,
                                unsafe_vars, diagnosed_vars, span
                            )
                        }
                    },
                    _ => {}
                }
            }
        },
        Type::TupleType { elements } => {
            for element in elements {
                audit_fail_payload_type(
                    ctx, fn_name, element, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::PtrType { pointee } =>
            audit_fail_payload_type(
                ctx, fn_name, pointee, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            ),
        _ => {}
    }
}

fn type_contains_exact(ty: Type, needle: Type) -> Bool {
    if types_equal(ty, needle) { return true }
    match ty {
        Type::FnType { params, return_type, effects } => {
            for param in params {
                if type_contains_exact(param, needle) { return true }
            }
            if type_contains_exact(return_type, needle) { return true }
            for eff in effects.effects {
                match eff {
                    Effect::FailEffect { error_type } => {
                        if type_contains_exact(error_type, needle) { return true }
                    },
                    Effect::MutEffect { state_type } => {
                        if type_contains_exact(state_type, needle) { return true }
                    },
                    Effect::CustomEffect { type_args, .. } => {
                        for arg in type_args {
                            if type_contains_exact(arg, needle) { return true }
                        }
                    },
                    _ => {}
                }
            }
            false
        },
        Type::StructType { type_params, .. } => {
            for param in type_params {
                if type_contains_exact(param, needle) { return true }
            }
            false
        },
        Type::EnumType { type_params, .. } => {
            for param in type_params {
                if type_contains_exact(param, needle) { return true }
            }
            false
        },
        Type::GenericType { base, args } => {
            if type_contains_exact(base, needle) { return true }
            for arg in args {
                if type_contains_exact(arg, needle) { return true }
            }
            false
        },
        Type::RecordType { fields, .. } => {
            for field in fields {
                if type_contains_exact(field.ty, needle) { return true }
            }
            false
        },
        Type::EffectRowType { effects, .. } => {
            for eff in effects {
                match eff {
                    Effect::FailEffect { error_type } => {
                        if type_contains_exact(error_type, needle) { return true }
                    },
                    Effect::MutEffect { state_type } => {
                        if type_contains_exact(state_type, needle) { return true }
                    },
                    Effect::CustomEffect { type_args, .. } => {
                        for arg in type_args {
                            if type_contains_exact(arg, needle) { return true }
                        }
                    },
                    _ => {}
                }
            }
            false
        },
        Type::TupleType { elements } => {
            for element in elements {
                if type_contains_exact(element, needle) { return true }
            }
            false
        },
        Type::PtrType { pointee } => type_contains_exact(pointee, needle),
        _ => false
    }
}

fn unsafe_structured_assoc_origin(
    ctx: InferCtx, fn_name: Str, payload: Type
) -> Str? {
    match ctx.rebind_assoc_provenance.get(fn_name) {
        some(entries) => {
            for entry in entries {
                match entry.check_type {
                    Type::TypeVar { .. } => {},
                    checked_shape => {
                        let represented_by_scheme = match entry.registration_type {
                            some(registration_shape) =>
                                types_equal(checked_shape, registration_shape),
                            none => false
                        }
                        if !represented_by_scheme &&
                           type_contains_exact(payload, checked_shape) {
                            let trait_display = nominal_display_name(entry.trait_name)
                            return some(
                                "${entry.owner_name}::${entry.assoc_name} (${trait_display})"
                            )
                        }
                    }
                }
            }
        },
        none => {}
    }
    none
}

fn audit_fail_row(
    mut ctx: InferCtx,
    fn_name: Str,
    row: EffectRow,
    mapping: Map<Int, Type>,
    original_scheme_vars: Set<Int>,
    mut unsafe_vars: Set<Int>,
    mut diagnosed_vars: Set<Int>,
    span: Span
) {
    for eff in row.effects {
        match eff {
            Effect::FailEffect { error_type } => {
                match unsafe_structured_assoc_origin(ctx, fn_name, error_type) {
                    some(origin) => {
                        let display = nominal_display_name(fn_name)
                        let detail = "associated type '${origin}' was constrained to a structure that the registration scheme cannot represent"
                        let _ = type_error(ctx.sink, E0503,
                            "Cannot rebind fail payload in '${display}': ${detail}",
                            span,
                            DiagnosticContext::TraitError { detail: detail })
                    },
                    none => {}
                }
                audit_fail_payload_type(
                    ctx, fn_name, error_type, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            },
            _ => {}
        }
    }
}

fn audit_fail_rows_in_type(
    mut ctx: InferCtx,
    fn_name: Str,
    ty: Type,
    mapping: Map<Int, Type>,
    original_scheme_vars: Set<Int>,
    mut unsafe_vars: Set<Int>,
    mut diagnosed_vars: Set<Int>,
    span: Span
) {
    match ty {
        Type::FnType { params, return_type, effects } => {
            audit_fail_row(
                ctx, fn_name, effects, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            )
            for param in params {
                audit_fail_rows_in_type(
                    ctx, fn_name, param, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
            audit_fail_rows_in_type(
                ctx, fn_name, return_type, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            )
        },
        Type::StructType { type_params, .. } => {
            for tp in type_params {
                audit_fail_rows_in_type(
                    ctx, fn_name, tp, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::EnumType { type_params, .. } => {
            for tp in type_params {
                audit_fail_rows_in_type(
                    ctx, fn_name, tp, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::GenericType { base, args } => {
            audit_fail_rows_in_type(
                ctx, fn_name, base, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            )
            for arg in args {
                audit_fail_rows_in_type(
                    ctx, fn_name, arg, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::RecordType { fields, .. } => {
            for field in fields {
                audit_fail_rows_in_type(
                    ctx, fn_name, field.ty, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::TupleType { elements } => {
            for element in elements {
                audit_fail_rows_in_type(
                    ctx, fn_name, element, mapping, original_scheme_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            }
        },
        Type::PtrType { pointee } =>
            audit_fail_rows_in_type(
                ctx, fn_name, pointee, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            ),
        _ => {}
    }
}

// Preserve the registration-time parameter skeleton. Checked shapes are used
// only to update effect rows of structurally corresponding function nodes.
// The one expansion is an unquantified registration TypeVar refined directly
// to a FnType; this is required for unannotated higher-order parameters.
fn rebind_param_fn_rows(
    mut ctx: InferCtx,
    fn_name: Str,
    reg_ty: Type,
    check_ty: Type,
    mapping: Map<Int, Type>,
    original_type_vars: List<Int>,
    original_scheme_vars: Set<Int>,
    mut row_candidates: Set<Int>,
    mut monomorphic_expansion_vars: Set<Int>,
    mut unsafe_vars: Set<Int>,
    mut diagnosed_vars: Set<Int>,
    span: Span
) -> Type {
    match (reg_ty, check_ty) {
        (Type::TypeVar { id, name },
         Type::FnType { params: check_params, return_type: check_ret, effects: check_effects }) => {
            let registered = Type::TypeVar { id: id, name: name }
            let checked = Type::FnType {
                params: check_params, return_type: check_ret, effects: check_effects
            }
            if original_type_vars.contains(id) {
                report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
                return registered
            }

            audit_fail_rows_in_type(
                ctx, fn_name, checked, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            )
            let mapped = apply_subst_map(mapping, checked)
            let mut mapped_free: Set<Int> = set_new()
            collect_free_vars(mapped, mapped_free)
            let mut sorted_free = mapped_free.to_list()
            sorted_free.sort()
            for free_id in sorted_free {
                if !original_scheme_vars.contains(free_id) {
                    monomorphic_expansion_vars.insert(free_id)
                    match ctx.env.scope.var_bounds.get(free_id) {
                        some(bounds) => {
                            if bounds.len() > 0 && !diagnosed_vars.contains(free_id) {
                                diagnosed_vars.insert(free_id)
                                unsafe_vars.insert(free_id)
                                let mut traits = bounds.to_list()
                                traits.sort()
                                let display = nominal_display_name(fn_name)
                                let traits_display = traits.join(", ")
                                let detail = "inferred higher-order parameter variable has untracked obligations: ${traits_display}"
                                let _ = type_error(ctx.sink, E0503,
                                    "Cannot rebind inferred higher-order parameter in '${display}': ${detail}",
                                    span,
                                    DiagnosticContext::TraitError { detail: detail })
                            }
                        },
                        none => {}
                    }
                }
            }
            mapped
        },
        (Type::TypeVar { id, name }, checked) => {
            let registered = Type::TypeVar { id: id, name: name }
            if type_contains_fn(checked) {
                report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
            }
            registered
        },
        (Type::FnType { params: reg_params, return_type: reg_ret, effects: reg_effects },
         Type::FnType { params: check_params, return_type: check_ret, effects: check_effects }) => {
            let registered = Type::FnType {
                params: reg_params, return_type: reg_ret, effects: reg_effects
            }
            let checked = Type::FnType {
                params: check_params, return_type: check_ret, effects: check_effects
            }
            if reg_params.len() != check_params.len() {
                report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
                return registered
            }

            audit_fail_row(
                ctx, fn_name, check_effects, mapping, original_scheme_vars,
                unsafe_vars, diagnosed_vars, span
            )
            let mapped_effects = apply_subst_row_map(mapping, check_effects)
            match reg_effects.tail {
                some(owner_id) => {
                    if original_type_vars.contains(owner_id) {
                        collect_free_vars(Type::EffectRowType {
                            effects: mapped_effects.effects, tail: mapped_effects.tail
                        }, row_candidates)
                    }
                },
                none => {}
            }

            let mut rebound_params: List<Type> = []
            let mut i = 0
            while i < reg_params.len() {
                match (reg_params.get(i), check_params.get(i)) {
                    (some(reg_param), some(check_param)) =>
                        rebound_params.push(rebind_param_fn_rows(
                            ctx, fn_name, reg_param, check_param, mapping,
                            original_type_vars, original_scheme_vars,
                            row_candidates, monomorphic_expansion_vars,
                            unsafe_vars, diagnosed_vars, span
                        )),
                    _ => {}
                }
                i = i + 1
            }
            let rebound_ret = rebind_param_fn_rows(
                ctx, fn_name, reg_ret, check_ret, mapping,
                original_type_vars, original_scheme_vars,
                row_candidates, monomorphic_expansion_vars,
                unsafe_vars, diagnosed_vars, span
            )
            Type::FnType {
                params: rebound_params,
                return_type: rebound_ret,
                effects: mapped_effects
            }
        },
        (Type::StructType { name: reg_name, type_params: reg_args },
         Type::StructType { name: check_name, type_params: check_args }) => {
            let registered = Type::StructType { name: reg_name, type_params: reg_args }
            let checked = Type::StructType { name: check_name, type_params: check_args }
            if reg_name != check_name || reg_args.len() != check_args.len() {
                if type_contains_fn(registered) || type_contains_fn(checked) {
                    report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
                }
                return registered
            }
            let mut rebound_args: List<Type> = []
            let mut i = 0
            while i < reg_args.len() {
                match (reg_args.get(i), check_args.get(i)) {
                    (some(reg_arg), some(check_arg)) =>
                        rebound_args.push(rebind_param_fn_rows(
                            ctx, fn_name, reg_arg, check_arg, mapping,
                            original_type_vars, original_scheme_vars,
                            row_candidates, monomorphic_expansion_vars,
                            unsafe_vars, diagnosed_vars, span
                        )),
                    _ => {}
                }
                i = i + 1
            }
            Type::StructType { name: reg_name, type_params: rebound_args }
        },
        (Type::EnumType { name: reg_name, type_params: reg_args },
         Type::EnumType { name: check_name, type_params: check_args }) => {
            let registered = Type::EnumType { name: reg_name, type_params: reg_args }
            let checked = Type::EnumType { name: check_name, type_params: check_args }
            if reg_name != check_name || reg_args.len() != check_args.len() {
                if type_contains_fn(registered) || type_contains_fn(checked) {
                    report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
                }
                return registered
            }
            let mut rebound_args: List<Type> = []
            let mut i = 0
            while i < reg_args.len() {
                match (reg_args.get(i), check_args.get(i)) {
                    (some(reg_arg), some(check_arg)) =>
                        rebound_args.push(rebind_param_fn_rows(
                            ctx, fn_name, reg_arg, check_arg, mapping,
                            original_type_vars, original_scheme_vars,
                            row_candidates, monomorphic_expansion_vars,
                            unsafe_vars, diagnosed_vars, span
                        )),
                    _ => {}
                }
                i = i + 1
            }
            Type::EnumType { name: reg_name, type_params: rebound_args }
        },
        (Type::TupleType { elements: reg_elements },
         Type::TupleType { elements: check_elements }) => {
            let registered = Type::TupleType { elements: reg_elements }
            let checked = Type::TupleType { elements: check_elements }
            if reg_elements.len() != check_elements.len() {
                if type_contains_fn(registered) || type_contains_fn(checked) {
                    report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
                }
                return registered
            }
            let mut rebound_elements: List<Type> = []
            let mut i = 0
            while i < reg_elements.len() {
                match (reg_elements.get(i), check_elements.get(i)) {
                    (some(reg_element), some(check_element)) =>
                        rebound_elements.push(rebind_param_fn_rows(
                            ctx, fn_name, reg_element, check_element, mapping,
                            original_type_vars, original_scheme_vars,
                            row_candidates, monomorphic_expansion_vars,
                            unsafe_vars, diagnosed_vars, span
                        )),
                    _ => {}
                }
                i = i + 1
            }
            Type::TupleType { elements: rebound_elements }
        },
        (Type::GenericType { base: reg_base, args: reg_args },
         Type::GenericType { base: check_base, args: check_args }) => {
            let registered = Type::GenericType { base: reg_base, args: reg_args }
            let checked = Type::GenericType { base: check_base, args: check_args }
            if reg_args.len() != check_args.len() {
                if type_contains_fn(registered) || type_contains_fn(checked) {
                    report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
                }
                return registered
            }
            let rebound_base = rebind_param_fn_rows(
                ctx, fn_name, reg_base, check_base, mapping,
                original_type_vars, original_scheme_vars,
                row_candidates, monomorphic_expansion_vars,
                unsafe_vars, diagnosed_vars, span
            )
            let mut rebound_args: List<Type> = []
            let mut i = 0
            while i < reg_args.len() {
                match (reg_args.get(i), check_args.get(i)) {
                    (some(reg_arg), some(check_arg)) =>
                        rebound_args.push(rebind_param_fn_rows(
                            ctx, fn_name, reg_arg, check_arg, mapping,
                            original_type_vars, original_scheme_vars,
                            row_candidates, monomorphic_expansion_vars,
                            unsafe_vars, diagnosed_vars, span
                        )),
                    _ => {}
                }
                i = i + 1
            }
            Type::GenericType { base: rebound_base, args: rebound_args }
        },
        (Type::RecordType { fields: reg_fields, tail: reg_tail, tail_name: reg_tail_name },
         Type::RecordType { fields: check_fields, tail: check_tail, tail_name: check_tail_name }) => {
            let registered = Type::RecordType {
                fields: reg_fields, tail: reg_tail, tail_name: reg_tail_name
            }
            let checked = Type::RecordType {
                fields: check_fields, tail: check_tail, tail_name: check_tail_name
            }
            let mut reliable = reg_fields.len() == check_fields.len()
            for reg_field in reg_fields {
                let mut found = false
                for check_field in check_fields {
                    if reg_field.name == check_field.name { found = true }
                }
                if !found { reliable = false }
            }
            if !reliable {
                if type_contains_fn(registered) || type_contains_fn(checked) {
                    report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
                }
                return registered
            }

            let mut rebound_fields: List<RecordField> = []
            for reg_field in reg_fields {
                let mut found = false
                let mut check_field_type = UNIT
                for check_field in check_fields {
                    if reg_field.name == check_field.name {
                        found = true
                        check_field_type = check_field.ty
                    }
                }
                if found {
                    rebound_fields.push(RecordField {
                        name: reg_field.name,
                        ty: rebind_param_fn_rows(
                            ctx, fn_name, reg_field.ty, check_field_type, mapping,
                            original_type_vars, original_scheme_vars,
                            row_candidates, monomorphic_expansion_vars,
                            unsafe_vars, diagnosed_vars, span
                        )
                    })
                }
            }
            Type::RecordType {
                fields: rebound_fields, tail: reg_tail, tail_name: reg_tail_name
            }
        },
        (Type::PtrType { pointee: reg_pointee },
         Type::PtrType { pointee: check_pointee }) =>
            Type::PtrType {
                pointee: rebind_param_fn_rows(
                    ctx, fn_name, reg_pointee, check_pointee, mapping,
                    original_type_vars, original_scheme_vars,
                    row_candidates, monomorphic_expansion_vars,
                    unsafe_vars, diagnosed_vars, span
                )
            },
        (registered, checked) => {
            if type_contains_fn(registered) || type_contains_fn(checked) {
                report_rebind_shape_mismatch(ctx, fn_name, registered, checked, span)
            }
            registered
        }
    }
}

// Shared exact-scheme rebind. Top-level functions and impl methods both pass
// their own authoritative registration scheme through this one algorithm.
fn rebind_checked_fn_scheme(
    mut ctx: InferCtx, name: Str, scheme: TypeScheme,
    params: List<HParam>, return_type: Type,
    effects: EffectRow, span: Span
) -> TypeScheme {
    let mut original_scheme_vars: Set<Int> = set_new()
    collect_free_vars(scheme.ty, original_scheme_vars)
    // Associated-type variables may be owned exclusively by a SchemeBound
    // constraint and not occur in the registration-time function shape until
    // an open callback row is refined.
    for owned_var in scheme.type_vars {
        original_scheme_vars.insert(owned_var)
    }
    for scheme_bound in scheme.bounds {
        original_scheme_vars.insert(scheme_bound.type_var)
        for constraint in scheme_bound.assoc_constraints {
            collect_free_vars(constraint.ty, original_scheme_vars)
        }
    }
    match scheme.ty {
            Type::FnType { params: reg_params, return_type: reg_ret, effects: reg_effects } => {
                // Build mapping: check-time var id → registration-time var id
                // by comparing resolved params with registered params position-by-position.
                let mut var_mapping: Map<Int, Type> = map_new()
                let mut structural_conflicts: Set<Int> = set_new()
                let mut pi = 0
                for p in params {
                    match reg_params.get(pi) {
                        some(reg_p) => build_var_mapping(
                            p.ty, reg_p, var_mapping, structural_conflicts
                        ),
                        none => {}
                    }
                    pi = pi + 1
                }
                // Return/effect positions can own variables that never appear
                // in ordinary parameters.
                build_var_mapping(
                    return_type, reg_ret, var_mapping, structural_conflicts
                )
                build_effect_var_mapping(
                    effects, reg_effects, var_mapping, structural_conflicts
                )

                // Reconcile the structural candidates above with the
                // owner-qualified associated-type targets captured before
                // cleanup. A check variable unified with both T::Item and some
                // other registered variable represents an equality that the
                // current scheme cannot publish, so it must fail closed.
                let mut assoc_targets: Map<Int, Type> = map_new()
                let mut assoc_unsafe_vars: Set<Int> = set_new()
                match ctx.rebind_assoc_provenance.get(name) {
                    some(entries) => {
                        for entry in entries {
                            match entry.check_type {
                                Type::TypeVar { id: check_var_id, .. } => {
                                    if structural_conflicts.contains(check_var_id) {
                                        // Only conflicts on the associated
                                        // payload identity are relevant here.
                                        // Ordinary generic/row conflicts may
                                        // already be represented by the
                                        // registration scheme and must not
                                        // poison unrelated fail<T> payloads.
                                        assoc_unsafe_vars.insert(check_var_id)
                                    } else {
                                        match entry.registration_type {
                                            some(target) => {
                                                match assoc_targets.get(check_var_id) {
                                                    some(existing) => {
                                                        if !types_equal(existing, target) {
                                                            // A single check-time
                                                            // variable was unified
                                                            // from two different
                                                            // associated-type owners.
                                                            assoc_unsafe_vars.insert(check_var_id)
                                                        }
                                                    },
                                                    none => assoc_targets.insert(check_var_id, target)
                                                }
                                            },
                                            none => assoc_unsafe_vars.insert(check_var_id)
                                        }
                                    }
                                },
                                // Structured associated types are audited
                                // directly at each new fail payload below. They
                                // cannot be represented as a TypeVar substitution.
                                _ => {}
                            }
                        }
                    },
                    none => {}
                }
                let mut sorted_assoc_ids = assoc_targets.keys()
                sorted_assoc_ids.sort()
                for check_id in sorted_assoc_ids {
                    match assoc_targets.get(check_id) {
                        some(target) => {
                            if !assoc_unsafe_vars.contains(check_id) {
                                match var_mapping.get(check_id) {
                                    some(structural_target) => {
                                        if !types_equal(structural_target, target) {
                                            assoc_unsafe_vars.insert(check_id)
                                        }
                                    },
                                    none => {
                                        // Owner-qualified provenance supplies
                                        // the otherwise missing identity.
                                        var_mapping.insert(check_id, target)
                                    }
                                }
                            }
                        },
                        none => {}
                    }
                }

                // Map the resolved return type back to registration-time vars
                let mapped_ret = apply_subst_map(var_mapping, return_type)

                // Also map effects
                let mapped_effects = apply_subst_row_map(var_mapping, effects)

                // Preserve only checked effect-row refinements inside the
                // registration parameter skeleton. Arbitrary inferred shapes
                // must not become a new public parameter ABI.
                let mut mapped_params: List<Type> = []
                let mut param_row_candidates: Set<Int> = set_new()
                let mut monomorphic_expansion_vars: Set<Int> = set_new()
                let mut unsafe_provenance_vars = assoc_unsafe_vars
                let mut diagnosed_vars: Set<Int> = set_new()
                audit_fail_row(
                    ctx, name, effects, var_mapping, original_scheme_vars,
                    unsafe_provenance_vars, diagnosed_vars, span
                )
                let mut mapped_pi = 0
                for p in params {
                    match reg_params.get(mapped_pi) {
                        some(reg_param) =>
                            mapped_params.push(rebind_param_fn_rows(
                                ctx, name, reg_param, p.ty, var_mapping,
                                scheme.type_vars, original_scheme_vars,
                                param_row_candidates, monomorphic_expansion_vars,
                                unsafe_provenance_vars, diagnosed_vars, span
                            )),
                        none => {}
                    }
                    mapped_pi = mapped_pi + 1
                }

                // Generalize only outer-row variables and parameter-row
                // variables owned by an originally quantified registration
                // tail. Mono→Fn expansion variables remain shared.
                // Mirroring infer_ctx::generalize is important here: a
                // monomorphic env variable (e.g. an unannotated `raise_arg(x)`)
                // must remain shared, while a body-local/callee-instantiation
                // variable gets a fresh instance at every call site.
                let mut row_free: Set<Int> = set_new()
                for candidate in param_row_candidates { row_free.insert(candidate) }
                collect_free_vars(Type::EffectRowType {
                    effects: mapped_effects.effects, tail: mapped_effects.tail
                }, row_free)
                let env_free = free_type_vars_in_env(ctx.env, empty_subst())
                let mut new_type_vars = list_clone(scheme.type_vars)
                let mut new_bounds = list_clone(scheme.bounds)
                let mut sorted_row_free = row_free.to_list()
                sorted_row_free.sort()
                for v in sorted_row_free {
                    if new_type_vars.contains(v) == false &&
                       env_free.contains(v) == false &&
                       monomorphic_expansion_vars.contains(v) == false &&
                       unsafe_provenance_vars.contains(v) == false {
                        new_type_vars.push(v)

                        // instantiate() records trait obligations for fresh
                        // variables in var_bounds.  Preserve those obligations
                        // when the propagated effect variable is generalized,
                        // using the same deterministic reconstruction contract
                        // as infer_ctx::generalize.  Existing SchemeBounds —
                        // including associated constraints — are left intact.
                        match ctx.env.scope.var_bounds.get(v) {
                            some(traits) => {
                                let mut sorted_traits = traits.to_list()
                                sorted_traits.sort()
                                for trait_name in sorted_traits {
                                    let exists = new_bounds.any(fn(b) {
                                        b.type_var == v && b.trait_name == trait_name
                                    })
                                    if !exists {
                                        new_bounds.push(SchemeBound {
                                            type_var: v,
                                            trait_name: trait_name,
                                            assoc_constraints: []
                                        })
                                    }
                                }
                            },
                            none => {},
                        }
                    }
                }

                let new_type = Type::FnType {
                    params: mapped_params, return_type: mapped_ret, effects: mapped_effects
                }
                TypeScheme {
                    ..scheme,
                    ty: new_type,
                    type_vars: new_type_vars,
                    bounds: new_bounds
                }
            },
            _ => scheme
    }
}

fn rebind_fn_type(
    mut ctx: InferCtx, name: Str, params: List<HParam>, return_type: Type,
    effects: EffectRow, span: Span, registration_scheme: TypeScheme?
) {
    match registration_scheme {
        some(scheme) => {
            let rebound = rebind_checked_fn_scheme(
                ctx, name, scheme, params, return_type, effects, span)
            rebind_fn_scheme_with_alias(ctx, name, rebound)
        },
        none => {}
    }
}

// Build a var-id mapping by structurally comparing two types.
// If check_ty = TypeVar(?42) and reg_ty = TypeVar(?1), records ?42 → ?1.
fn record_var_mapping(
    check_id: Int,
    registration_type: Type,
    mut mapping: Map<Int, Type>,
    mut conflicts: Set<Int>
) {
    // update_fn_effects runs immediately before rebind and may place a
    // check-time variable into the scheme's outer effect row. Mapping that
    // variable to itself carries no registration identity; treating it as a
    // candidate would conflict with the real parameter/bound target.
    match registration_type {
        Type::TypeVar { id: registration_id, .. } => {
            if registration_id == check_id { return }
        },
        _ => {}
    }
    match mapping.get(check_id) {
        some(existing) => {
            if !types_equal(existing, registration_type) {
                conflicts.insert(check_id)
            }
        },
        none => mapping.insert(check_id, registration_type)
    }
}

fn build_var_mapping(
    check_ty: Type,
    reg_ty: Type,
    mut mapping: Map<Int, Type>,
    mut conflicts: Set<Int>
) {
    match (check_ty, reg_ty) {
        (Type::TypeVar { id: check_id, .. }, _) => {
            record_var_mapping(check_id, reg_ty, mapping, conflicts)
        },
        (Type::FnType { params: cp, return_type: cr, effects: ce },
         Type::FnType { params: rp, return_type: rr, effects: re }) => {
            let mut i = 0
            for c in cp {
                match rp.get(i) {
                    some(r) => build_var_mapping(c, r, mapping, conflicts),
                    none => {}
                }
                i = i + 1
            }
            build_var_mapping(cr, rr, mapping, conflicts)
            build_effect_var_mapping(ce, re, mapping, conflicts)
        },
        (Type::StructType { name: cn, type_params: ct },
         Type::StructType { name: rn, type_params: rt }) => {
            if cn == rn && ct.len() == rt.len() {
                let mut i = 0
                for c in ct {
                    match rt.get(i) {
                        some(r) => build_var_mapping(c, r, mapping, conflicts),
                        none => {}
                    }
                    i = i + 1
                }
            }
        },
        (Type::EnumType { name: cn, type_params: ct },
         Type::EnumType { name: rn, type_params: rt }) => {
            if cn == rn && ct.len() == rt.len() {
                let mut i = 0
                for c in ct {
                    match rt.get(i) {
                        some(r) => build_var_mapping(c, r, mapping, conflicts),
                        none => {}
                    }
                    i = i + 1
                }
            }
        },
        (Type::TupleType { elements: ce }, Type::TupleType { elements: re }) => {
            if ce.len() == re.len() {
                let mut i = 0
                for c in ce {
                    match re.get(i) {
                        some(r) => build_var_mapping(c, r, mapping, conflicts),
                        none => {}
                    }
                    i = i + 1
                }
            }
        },
        (Type::GenericType { base: cb, args: ca },
         Type::GenericType { base: rb, args: ra }) => {
            if ca.len() == ra.len() {
                build_var_mapping(cb, rb, mapping, conflicts)
                let mut i = 0
                for c in ca {
                    match ra.get(i) {
                        some(r) => build_var_mapping(c, r, mapping, conflicts),
                        none => {}
                    }
                    i = i + 1
                }
            }
        },
        (Type::RecordType { fields: cf, tail: ct, .. },
         Type::RecordType { fields: rf, tail: rt, .. }) => {
            // Common named fields remain reliable even when an open
            // registration row has expanded with additional checked fields.
            // Skipping them would hide owner conflicts nested in those fields.
            for check_field in cf {
                for reg_field in rf {
                    if check_field.name == reg_field.name {
                        build_var_mapping(
                            check_field.ty, reg_field.ty, mapping, conflicts
                        )
                    }
                }
            }

            // Tail identity is only reliable when both visible field sets are
            // exactly the same. Extra/missing fields may have been absorbed by
            // an open row and change what the tail denotes.
            let mut same_fields = cf.len() == rf.len()
            for reg_field in rf {
                let mut found = false
                for check_field in cf {
                    if check_field.name == reg_field.name { found = true }
                }
                if !found { same_fields = false }
            }
            if same_fields {
                match (ct, rt) {
                    (some(check_tail), some(reg_tail)) => {
                        record_var_mapping(
                            check_tail,
                            Type::TypeVar { id: reg_tail, name: none },
                            mapping,
                            conflicts
                        )
                    },
                    _ => {}
                }
            }
        },
        (Type::PtrType { pointee: cp }, Type::PtrType { pointee: rp }) =>
            build_var_mapping(cp, rp, mapping, conflicts),
        _ => {}
    }
}

fn build_effect_var_mapping(
    check_row: EffectRow,
    reg_row: EffectRow,
    mut mapping: Map<Int, Type>,
    mut conflicts: Set<Int>
) {
    match (check_row.tail, reg_row.tail) {
        (some(check_tail), some(reg_tail)) => {
            record_var_mapping(
                check_tail,
                Type::TypeVar { id: reg_tail, name: none },
                mapping,
                conflicts
            )
        },
        _ => {},
    }

    for check_eff in check_row.effects {
        for reg_eff in reg_row.effects {
            if effects_match_kind(check_eff, reg_eff) {
                match (check_eff, reg_eff) {
                    (Effect::FailEffect { error_type: ct }, Effect::FailEffect { error_type: rt }) =>
                        build_var_mapping(ct, rt, mapping, conflicts),
                    (Effect::MutEffect { state_type: ct }, Effect::MutEffect { state_type: rt }) =>
                        build_var_mapping(ct, rt, mapping, conflicts),
                    (Effect::CustomEffect { type_args: ca, .. }, Effect::CustomEffect { type_args: ra, .. }) => {
                        let mut i = 0
                        while i < ca.len() && i < ra.len() {
                            match (ca.get(i), ra.get(i)) {
                                (some(ct), some(rt)) =>
                                    build_var_mapping(ct, rt, mapping, conflicts),
                                _ => {},
                            }
                            i = i + 1
                        }
                    },
                    _ => {},
                }
            }
        }
    }
}

// ============================================================
// Default effect handler cycle detection
// ============================================================

fn check_default_effect_cycles(mut ctx: InferCtx, decls: List<Decl>) {
    // Build span lookup for error reporting
    let mut effect_spans: Map<Str, Span> = map_new()
    collect_effect_spans(decls, effect_spans)

    // DFS-based cycle detection on effect_default_deps graph
    // States: 0 = unvisited, 1 = in-progress (on stack), 2 = done
    let mut state: Map<Str, Int> = map_new()
    let mut path: List<Str> = []

    let mut sorted_edd = ctx.effect_default_deps.entries()
    sorted_edd.sort_by(compare_by_first)
    for entry in sorted_edd {
        let (eff_name, _) = entry
        if !state.contains_key(eff_name) {
            dfs_detect_cycle(ctx, eff_name, state, path, effect_spans)
        }
    }
}

fn collect_effect_spans(decls: List<Decl>, mut spans: Map<Str, Span>) {
    for decl in decls {
        match decl {
            Decl::Effect { name, span, .. } => {
                spans.insert(name, span)
            },
            Decl::ModBlock { decls: mod_decls, .. } => {
                collect_effect_spans(mod_decls, spans)
            },
            _ => {}
        }
    }
}

fn dfs_detect_cycle(mut ctx: InferCtx, name: Str, mut state: Map<Str, Int>, mut path: List<Str>, effect_spans: Map<Str, Span>) {
    state.insert(name, 1)  // mark as in-progress
    path.push(name)

    match ctx.effect_default_deps.get(name) {
        some(deps) => {
            for dep in deps {
                match state.get(dep) {
                    some(s) => {
                        if s == 1 {
                            // Found a cycle: build cycle path description
                            let mut cycle_parts: List<Str> = []
                            let mut found_start = false
                            for p in path {
                                if p == dep { found_start = true }
                                if found_start { cycle_parts.push(nominal_display_name(p)) }
                            }
                            cycle_parts.push(nominal_display_name(dep))
                            let cycle_str = cycle_parts.join(" -> ")
                            let err_span = match effect_spans.get(name) {
                                some(sp) => sp,
                                none => Span { file: "", start: Position { line: 0, column: 0, offset: 0 }, end: Position { line: 0, column: 0, offset: 0 } }
                            }
                            let _ = type_error(ctx.sink, E0410,
                                "Cyclic dependency in default effect handlers: ${cycle_str}",
                                err_span,
                                DiagnosticContext::OtherContext { detail: some("cyclic default effect dependency") })
                        }
                        // s == 2 means already processed, no cycle through this node
                    },
                    none => {
                        // Unvisited: recurse
                        dfs_detect_cycle(ctx, dep, state, path, effect_spans)
                    }
                }
            }
        },
        none => {}
    }

    path.pop()
    state.insert(name, 2)  // mark as done
}

pub fn check(mut ctx: InferCtx, program: Program) -> HProgram {
    register_decls_two_phase(ctx, program.decls)
    let file_key = single_namespace_file_key(program)
    check_registered(ctx, program, file_key)
}

pub fn check_module_identity(
    mut ctx: InferCtx, program: Program,
    module_prefix: Str, file_key: Str
) -> HProgram {
    let qualified_decls = register_module_decls_two_phase(ctx, module_prefix, program.decls)
    let qualified = Program { uses: program.uses, decls: qualified_decls, span: program.span }
    check_registered(ctx, qualified, file_key)
}

fn check_registered(
    mut ctx: InferCtx, program: Program, file_key: Str
) -> HProgram {
    // Derive mutates canonical registries. Complete it before the lexical root
    // overlay snapshots any payload, so frame aliases always observe the
    // authoritative post-derive definitions.
    let derived_impls = run_derive_pass(ctx.env, ctx.sink)
    let project_active = ctx.project_namespace_file_key.is_some()
    enter_impl_check_root_frame(ctx, file_key)
    let mut entered_project_frame = false
    if project_active {
        entered_project_frame = enter_project_root_frame(ctx)
        if !entered_project_frame {
            panic("unreachable: resolver plan missing file root check frame")
        }
    }
    let result = check_registered_body(
        ctx, program, derived_impls) catch { _ => {
        if entered_project_frame {
            let _ = exit_project_namespace_frame(ctx)
        }
        exit_impl_check_frame(ctx)
        fail.raise(CompileError {})
    } }
    if entered_project_frame {
        let _ = exit_project_namespace_frame(ctx)
    }
    exit_impl_check_frame(ctx)
    result
}

fn check_registered_body(
    mut ctx: InferCtx, program: Program,
    derived_impls: List<DerivedImpl>
) -> HProgram {
    // Effect pre-pass: rebind impl-owner method cores with inferred effects.
    // Without this, callers defined before impl blocks see EMPTY_ROW effects from Pass 1.
    // The main pass re-checks with correct effects visible.
    // DiagnosticSink deduplication (by code+span) prevents double error reporting.
    let mut effect_decl_index = 0
    for decl in program.decls {
        match decl {
            Decl::Impl { target_type, type_params, trait_name, methods, span } => {
                let _ = some(check_impl_decl(
                    ctx, target_type, type_params, trait_name,
                    methods, span, effect_decl_index)) catch { _ => none }
            },
            _ => {}
        }
        effect_decl_index = effect_decl_index + 1
    }

    // B-122: Build SCC for fn/impl declaration ordering.
    // Callees are checked before callers so that rebinding makes resolved
    // return types visible to callers (fixing the #149 unsound ret-var hole).
    let registered_fns = collect_registered_fn_names(program.decls)
    let call_graph = build_call_graph(program.decls, registered_fns)
    let scc_groups = tarjan_scc(call_graph)

    // Build lookup before the inline pre-pass. Besides driving Phase 2b, this
    // distinguishes top-level SCC nodes that are already checked exactly once
    // below from inline nodes that need module-context prechecking.
    let mut fn_name_to_idx: Map<Str, Int> = map_new()
    let mut impl_node_to_idx: Map<Str, Int> = map_new()
    let mut idx = 0
    for decl in program.decls {
        match decl {
            Decl::Fn { name, .. } => {
                fn_name_to_idx.insert(name, idx)
            },
            Decl::Impl { target_type, trait_name, .. } => {
                let inode = match trait_name {
                    some(tn) => "impl::${target_type}::${tn}",
                    none => "impl::${target_type}"
                }
                impl_node_to_idx.insert(inode, idx)
            },
            _ => {}
        }
        idx = idx + 1
    }

    // Inline functions are emitted inside HDecl::ModBlock and therefore have
    // no direct program.decls index for Phase 2b below. Starting from those
    // nodes, follow caller -> callee edges and pre-check only that dependency
    // closure leaf-first. This includes file-root callees reached via super::,
    // while ordinary file modules with no inline functions do no extra work.
    let mut impl_fn_names: Set<Str> = set_new()
    collect_impl_scc_fn_names(program.decls, none, impl_fn_names)
    let mut inline_roots: Set<Str> = set_new()
    for name in registered_fns {
        if !fn_name_to_idx.contains_key(name) && !impl_fn_names.contains(name) {
            inline_roots.insert(name)
        }
    }
    let precheck_nodes = inline_dependency_closure(call_graph, inline_roots, impl_fn_names)
    for scc_group in scc_groups {
        for name in scc_group {
            if precheck_nodes.contains(name) {
                match fn_name_to_idx.get(name) {
                    some(i) => precheck_top_level_fn_at(ctx, program.decls, i),
                    none => { let _ = precheck_inline_fn(ctx, program.decls, name) }
                }
            }
        }
    }

    let mut hdecls: List<HDecl> = []
    let mut checked: Set<Int> = set_new()

    // Phase 1: Check non-fn/non-impl declarations in source order.
    // These (struct, enum, effect, trait, extern, const, type-alias, test, mod)
    // do not participate in the fn call graph.
    let mut di = 0
    for decl in program.decls {
        match decl {
            Decl::Fn { .. } => {},
            Decl::Impl { .. } => {},
            _ => {
                let result = some(check_one_decl_with_rebind(
                    ctx, decl, some(di), hdecls)) catch { _ => none }
                checked.insert(di)
            }
        }
        di = di + 1
    }

    // Phase 2a: Check impl blocks in source order (before top-level fns).
    // This re-checks impls with effects populated by the pre-pass.
    // Must happen before top-level fns so that method effects are visible
    // to callers (method calls are invisible to the call graph).
    let mut ii = 0
    for decl in program.decls {
        match decl {
            Decl::Impl { .. } => {
                if !checked.contains(ii) {
                    let result = some(check_one_decl_with_rebind(
                        ctx, decl, some(ii), hdecls)) catch { _ => none }
                    checked.insert(ii)
                }
            },
            _ => {}
        }
        ii = ii + 1
    }

    // Phase 2b: Check top-level fn declarations in SCC topological order.
    // tarjan_scc returns SCCs with leaf dependencies first (reverse topo),
    // so callees are checked before callers. After each check, rebinding
    // makes the resolved return type visible to subsequent callers.
    for scc_group in scc_groups {
        for name in scc_group {
            match fn_name_to_idx.get(name) {
                some(i) => {
                    if !checked.contains(i) {
                        match program.decls.get(i) {
                            some(decl) => {
                                let result = some(check_one_decl_with_rebind(
                                    ctx, decl, some(i), hdecls)) catch { _ => none }
                                checked.insert(i)
                            },
                            none => {}
                        }
                    }
                },
                none => {}
            }
        }
    }

    // Phase 3: Check any remaining unchecked decls (safety net for decls
    // not reached by SCC — e.g., dead code or decls with no call graph edges).
    let mut ri = 0
    for decl in program.decls {
        if !checked.contains(ri) {
            let result = some(check_one_decl_with_rebind(
                ctx, decl, some(ri), hdecls)) catch { _ => none }
        }
        ri = ri + 1
    }

    // Check for cyclic dependencies in default effect handlers
    check_default_effect_cycles(ctx, program.decls)

    // static_dicts is populated by dict_lower (checker pipeline) — empty here.
    // B-144/B-145: declarations contribute directly. In project mode the root
    // namespace frame is still active here, so explicitly imported externs are
    // visible transactionally in `structs`; capture their raw ABI identities
    // for codegen before the caller rolls the frame back. Unimported dependency
    // externs live only in `extern_structs` and therefore cannot enter this set.
    let mut extern_names = collect_extern_type_names(hdecls)
    if ctx.project_namespace_file_key.is_some() {
        for entry in ctx.env.types.structs.entries() {
            let (_, def) = entry
            if def.is_extern {
                extern_names.insert(def.name)
            }
        }
    }
    HProgram { decls: hdecls, derived_impls: derived_impls, boxed_vars: ctx.boxed_vars, static_dicts: [], extern_type_names: extern_names, drop_types: ctx.drop_types }
}

pub fn resolve_type_expr_public(mut ctx: InferCtx, texpr: TypeExpr) -> Type {
    resolve_type_expr(ctx, texpr)
}

pub fn check_prelude_decl(
    mut ctx: InferCtx, decl: Decl, file_key: Str, decl_index: Int
) -> HDecl {
    // Note: check_decl uses fail.raise internally. Due to the known limitation
    // where cross-module effect propagation doesn't work (effects registered as
    // EMPTY_ROW in Pass 1), we must explicitly surface the fail effect here so
    // callers pass the __ring_ev_fail evidence.
    enter_impl_check_root_frame(ctx, file_key)
    let result = some(check_decl(ctx, decl, some(decl_index))) catch { _ => {
        exit_impl_check_frame(ctx)
        fail.raise(CompileError {})
    } }
    exit_impl_check_frame(ctx)
    if false { fail.raise(CompileError {}) }
    result.unwrap()
}
