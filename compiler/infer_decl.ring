use types::{Type, Effect, EffectRow, UNIT, EMPTY_ROW, type_to_string, effect_to_string, nominal_display_name, effects_match_kind, types_equal}
use ast::{Program, Decl, Expr, Param, TypeExpr, TypeParam, Span, EffectOpDecl, EffectExpr,
    UseDecl}
use hir::{HDecl, HParam, HTypeParam, HExpr, HStmt, HProgram, DerivedImpl, TraitBound, HAssocType,
    HStructField, HEnumVariant, HEffectOp, HTraitMethod, HFieldAccessKind,
    HNominalStructFieldInit, HStructFieldInit,
    HMatchArm, HEffectHandler, HStringInterpPart, HLambdaCapture,
    HCallableTypeActual, HCallableEffectInstantiation,
    HCallableValueInstantiation,
    h_nominal_projection,
    HDelegateMethodPlan, HDelegateAssocPlan,
    HDefaultSpecializationPlan, make_h_default_specialization_plan,
    make_h_delegate_method_plan, make_h_delegate_assoc_plan,
    make_h_delegate_typed_plan, method_call_ref_callee_identity,
    h_type_param_source,
    DictRef, trait_dict_name,
    make_intrinsic_method_call_ref, make_concrete_method_call_ref,
    make_bound_method_call_ref,
    make_h_exact_call_plan,
    hexpr_type, hexpr_effects, hexpr_span,
    collect_extern_type_names, compare_by_first, extern_abi_leaf}
use hir_exact::{make_static_dict_ref}
use ir_identity::{SymbolRef, NominalFieldRef, HandledEffectRef,
    nominal_field_ref_index, symbol_ref_same,
    ImplOwnerRef, ImplMethodRef,
    impl_owner_ref_provider, impl_owner_ref_trait, impl_owner_ref_target,
    impl_owner_ref_same,
    impl_method_ref_member, impl_method_ref_owner, impl_method_ref_same,
    symbol_ref_declaration_site_path, symbol_ref_canonical_payload,
    registered_nominal_ref_symbol, registered_trait_ref_symbol,
    trait_method_ref_trait,
    trait_method_ref_member,
    trait_method_ref_source_member_index,
    trait_method_ref_callable_slot_index, trait_method_ref_name,
    make_module_body_ref, path_owner_for_module_body, make_path_ref,
    path_role_declaration, make_source_slot_ref, slot_domain_lexical,
    make_named_callee_ref, make_local_callee_ref, make_symbol_origin_ref,
    handled_effect_ref_same}
use ir_inventory::{ExecutableRef, BinderEntry,
    make_exact_static_dict_ref,
    CallableResourceContractFact, CallableResourceRoleFact,
    make_callable_resource_contract_fact,
    callable_resource_contract_parameter_roles,
    callable_resource_role_read, callable_resource_role_mutate,
    callable_resource_role_consume,
    make_named_executable_ref,
    make_anonymous_executable_ref,
    executable_ref_same}
use effect_contract::{TypedEffectHeaderSchema, TypedCallableEffectCtx,
    TypedEffectCtxLayout, TypedEffectCtxSource,
    empty_typed_effect_header_schema,
    typed_effect_header_schema_bindings,
    typed_effect_header_binding_raw_tail,
    make_empty_effect_ctx_source, make_typed_callable_effect_ctx,
    typed_callable_effect_ctx_binding, typed_effect_ctx_source_is_empty,
    typed_callable_effect_ctx_layout, typed_effect_ctx_layout_entries,
    typed_effect_ctx_lookup_instance, typed_effect_ctx_install_entries,
    typed_handled_effect_instances_from_row,
    typed_handled_effect_instance_is_fully_closed,
    typed_callable_header_has_closed_handled_instances,
    typed_runtime_actual_type_has_closed_handled_instances,
    typed_runtime_effect_actual_has_closed_handled_instances}
use env::{TypeScheme, SchemeBound, AssocConstraintEntry,
    ImplEntry,
    apply_subst, apply_subst_map,
    find_impl, find_impl_by_provider,
    find_impls_by_provider, find_delegate_child_provider_plan,
    optional_symbol_ref_same,
    delegate_child_provider_ref,
    delegate_child_provider_produced_owner_count,
    delegate_child_provider_had_semantic_error,
    has_impl, impl_target_symbol,
    compiler_owned_extern_manifest_entry,
    install_method_core, replace_impl_method_core,
    impl_method_core_as_scheme, impl_method_core_from_scheme,
    impl_method_core_type, impl_method_core_effect_schema,
    build_type_var_map, ordered_effect_tail_vars,
    build_definition_effect_header_schema,
    validate_effect_header_schema,
    instantiate_effect_header_schema}
use extern_manifest::{compiler_extern_manifest_entry_executable,
    compiler_extern_manifest_entry_resource}
use union_find::{UnionFind}
use unify::{empty_subst}
use diagnostics::{DiagnosticContext, DiagnosticNote, Severity}
use codes::{E0201, E0204, E0402, E0403, E0404, E0405, E0407, E0501, E0503, E0504, E0802, E0803}
use infer_ctx::{InferCtx, FnBoundsEntry, AssocRebindEntry,
    OwnerInferenceBatch, OwnerBatchCheckpoint, CallableFinalizationHeader,
    CompileError,
    validate_fn_bound_order,
    type_error, type_error_with_notes,
    unify_at, unify_at_noted,
    resolve_type_expr, resolve_self_type,
    make_callable_impl_definition_receipt,
    resolve_immediate_impl_owner_dicts,
    pending_dict_checkpoint, drain_pending_dicts, rollback_pending_dicts,
    assert_pending_dict_owner_closed,
    generalize, free_type_vars, resolve_mod_uses,
    enter_project_root_frame, enter_project_child_frame,
    exit_project_namespace_frame,
    enter_impl_check_root_frame, enter_impl_check_child_frame,
    exit_impl_check_frame, impl_check_owner, value_symbol_ref,
    commit_final_prelude_value_symbol_ref,
    current_impl_check_site, enter_executable_owner,
    exit_executable_owner,
    current_typed_callable_effect_ctx, effect_ctx_source_for_callable,
    current_typed_callable_effect_ctx_from_owner_batch,
    typed_effect_ctx_layout_for_row,
    typed_effect_ctx_layout_from_owner_batch,
    typed_effect_ctx_layout_from_published_schema,
    current_identity_file_key, semantic_parameter_binder,
    executable_effect_origin, publish_exact_callable_effect_header,
    begin_recursive_callable_group, end_recursive_callable_group,
    mark_recursive_callable_group_closed,
    owner_batch_checkpoint, rollback_owner_batch, detach_owner_batch,
    drain_owner_batch_dictionary_group, drain_owner_batch_dictionaries,
    stage_owner_batch_facts,
    preflight_owner_batches, publish_owner_batches,
    make_callable_finalization_header, project_owner_batch_receipts,
    begin_infer_mutation_journal, commit_infer_mutation_journal,
    rollback_infer_mutation_journal,
    journal_boxed_var_insert, journal_var_lambda_depth_set,
    journal_record_def_span, journal_mutable_var_insert,
    journal_let_def_insert, journal_mut_param_def_insert,
    journal_fn_mut_params_set}
use infer_helpers::{is_value_type, finalize_value_ident_no_solve,
    finalize_direct_callee_no_solve}
use resolver::{single_namespace_file_key}
use infer_register::{register_decls_two_phase, register_module_decls_two_phase,
    resolve_declared_effects, prefix_decl_name, insert_mod_aliases,
    collect_all_supertraits, inject_assoc_types_from_bounds,
    impl_owner_fn_bounds,
    resolve_trait_identity, resolve_nominal_identity}
use infer::{infer_block, infer_expr}
use zonk::{ZonkCtx, zonk_type, zonk_row, zonk_param, zonk_block, zonk_expr}
use derive::{run_derive_pass}
use scc::{build_call_graph, tarjan_scc, collect_registered_fn_names, collect_self_method_callees}

struct FnValidationContext {
    capability: EffectRow?,
    capability_span: Span?
}

struct FnDraft {
    name: Str,
    executable: ExecutableRef,
    impl_method_ref: ImplMethodRef?,
    registration_scheme: TypeScheme,
    inherited_type_var_ids: List<Int>,
    source_type_var_ids: List<Int>,
    is_pub: Bool,
    span: Span,
    type_params: List<HTypeParam>,
    trait_bounds: List<TraitBound>,
    params: List<HParam>,
    expected_return: Type,
    owner_effects: EffectRow,
    body: HExpr,
    raw_type_var_names: Map<Int, Str>,
    assoc_rebind_sources: List<AssocRebindEntry>,
    validation: FnValidationContext,
    batch: OwnerInferenceBatch
}

fn diagnostics_since_has_errors(ctx: InferCtx, checkpoint: Int) -> Bool {
    let recent = ctx.sink.items.slice(
        checkpoint, ctx.sink.items.len())
    for diagnostic in recent {
        match diagnostic.severity {
            Severity::SevError => return true,
            _ => {}
        }
    }
    false
}

struct StagedCallableClose {
    name: Str,
    executable: ExecutableRef,
    scheme: TypeScheme,
    span: Span
}

struct CachedImplClose {
    owner_ref: ImplOwnerRef,
    declarations: List<HDecl>
}

struct CachedValueClose {
    executable: ExecutableRef,
    declaration: HDecl
}

fn cached_value_declaration(
    values: List<CachedValueClose>, executable: ExecutableRef
) -> HDecl? {
    for value in values {
        if executable_ref_same(value.executable, executable) {
            return some(value.declaration)
        }
    }
    none
}

fn exact_h_type_params(
    ctx: InferCtx, source: List<TypeParam>, type_var_ids: List<Int>
) -> List<HTypeParam> {
    if source.len() != type_var_ids.len() {
        panic("HIR type parameters: registration arity differs")
    }
    let mut result: List<HTypeParam> = []
    for index in 0..source.len() {
        let parameter = source.get(index).unwrap()
        let mut bound_refs: List<SymbolRef> = []
        for bound in parameter.bounds {
            let trait_name = resolve_trait_identity(ctx, bound.trait_name)
            let trait_def = ctx.env.trait_reg.traits.get(
                trait_name).unwrap_or_else(fn() {
                panic("HIR type parameter: exact bound trait is absent")
            })
            bound_refs.push(registered_trait_ref_symbol(
                trait_def.owner_ref))
        }
        result.push(HTypeParam {
            source: parameter,
            type_var_id: type_var_ids.get(index).unwrap(),
            bound_refs: bound_refs
        })
    }
    result
}

fn exact_source_type_var_ids(
    scheme: TypeScheme, source_offset: Int, source_count: Int
) -> List<Int> {
    if source_offset < 0 || source_count < 0 ||
       source_offset + source_count > scheme.type_vars.len() {
        panic("HIR type parameters: registered source range is invalid")
    }
    let mut result: List<Int> = []
    for index in 0..source_count {
        result.push(scheme.type_vars.get(source_offset + index).unwrap())
    }
    result
}

fn with_call_effect_ctx(
    value: HExpr,
    effect_ctx: TypedEffectCtxSource
) -> HExpr {
    match value {
        HExpr::Call { callee, args, type_args, effect_instantiation,
                      resolved_dicts,
                      callee_ref, method_ref, system_host,
                      ty, effects, span, .. } => HExpr::Call {
            callee: callee, args: args, type_args: type_args,
            effect_instantiation: effect_instantiation,
            resolved_dicts: resolved_dicts,
            effect_ctx: effect_ctx,
            callee_ref: callee_ref, method_ref: method_ref,
            system_host: system_host, ty: ty, effects: effects, span: span
        },
        _ => panic("effect context: expected exact Call")
    }
}

// ============================================================
// Pass 2: Check declarations (from infer.ts)
// ============================================================

fn named_executable_for_def_id(
    ctx: InferCtx, def_id: Int?, detail: Str
) -> ExecutableRef {
    match def_id {
        some(id) => make_named_executable_ref(value_symbol_ref(ctx, id)),
        none => panic("${detail}: executable DefId is missing")
    }
}

fn test_executable_for_site(ctx: InferCtx, decl_index: Int) -> ExecutableRef {
    if decl_index < 0 { panic("test executable: declaration index is missing") }
    let (file_key, frame_index) = current_impl_check_site(ctx)
    let owner = path_owner_for_module_body(
        make_module_body_ref(
            file_key, "inline-frame:${frame_index.to_str()}"))
    make_anonymous_executable_ref(make_path_ref(
        owner, ["decl:${decl_index}", "test"], path_role_declaration()))
}

fn check_decl(
    mut ctx: InferCtx, decl: Decl, frame_decl_index: Int?,
    cached_impls: List<CachedImplClose>,
    cached_values: List<CachedValueClose>
) -> HDecl {
    let obligation_checkpoint = pending_dict_checkpoint(ctx)
    let result = some(check_decl_inner(
        ctx, decl, frame_decl_index,
        cached_impls, cached_values)) catch { _ => none }
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
    mut ctx: InferCtx, decl: Decl, frame_decl_index: Int?,
    cached_impls: List<CachedImplClose>,
    cached_values: List<CachedValueClose>
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
                frame_decl_index.unwrap_or(-1), FnValidationContext {
                    capability: none, capability_span: none
                }),
        Decl::Fn { name, type_params, params, return_type, declared_effects, body, is_pub, span, .. } =>
            check_fn_decl(ctx, name, type_params, params, return_type,
                declared_effects, body, is_pub, span,
                none, none, none, none, []),
        Decl::Test { description, body, span } =>
            check_test_decl(
                ctx, description, body, span,
                frame_decl_index.unwrap_or(-1)),
        Decl::Trait { name, type_params, methods, is_pub, span, .. } =>
            check_trait_decl(ctx, name, type_params, methods, is_pub, span),
        Decl::ExternFn { name, type_params, params, return_type, declared_effects, is_pub, span } =>
            check_extern_fn_decl(ctx, name, type_params, params, declared_effects, is_pub, span),
        Decl::ExternType { name, type_params, is_pub, span } => {
            let def = ctx.env.types.extern_structs.get(name).unwrap_or_else(fn() {
                panic("extern type HIR: registered definition is absent")
            })
            HDecl::ExternType {
                name: name,
                type_params: exact_h_type_params(
                    ctx, type_params, def.type_param_vars),
                is_pub: is_pub, span: span }
        },
        Decl::TypeAlias { name, is_pub, span, .. } => {
            match ctx.env.types.type_aliases.get(name) {
                some(alias) => HDecl::TypeAlias {
                    name: name, owner_ref: some(alias.owner_ref), ty: alias.ty,
                    is_pub: is_pub, span: span
                },
                // Preserve the existing error-recovery HIR path. Successful
                // source aliases always take the exact-owner branch above.
                none => HDecl::TypeAlias {
                    name: name, owner_ref: none, ty: UNIT,
                    is_pub: is_pub, span: span
                }
            }
        },
        Decl::Const { name, type_annotation, init, is_pub, span } =>
            check_const_decl(ctx, name, type_annotation, init, is_pub, span),
        Decl::ModBlock { name, uses, decls, required_effects, is_pub, span } =>
            check_mod_decl(
                ctx, name, uses, decls, required_effects,
                is_pub, span, frame_decl_index,
                cached_impls, cached_values),
        Decl::EffectAlias { name, is_pub, span, .. } =>
            HDecl::TypeAlias {
                name: name, owner_ref: none, ty: UNIT,
                is_pub: is_pub, span: span },
        Decl::Delegate { span, .. } =>
            // Delegate is only valid inside impl blocks; handled by check_impl_decl
            HDecl::TypeAlias {
                name: "<delegate>", owner_ref: none, ty: UNIT,
                is_pub: false, span: span },
        Decl::AssocType { span, .. } =>
            // Associated types are only valid inside trait/impl blocks; handled there
            HDecl::TypeAlias {
                name: "<assoc_type>", owner_ref: none, ty: UNIT,
                is_pub: false, span: span }
    }
}

fn cached_impl_declarations(
    cached_impls: List<CachedImplClose>, owner_ref: ImplOwnerRef
) -> List<HDecl>? {
    for cached in cached_impls {
        if impl_owner_ref_same(cached.owner_ref, owner_ref) {
            return some(cached.declarations)
        }
    }
    none
}

fn check_mod_decl_body(
    mut ctx: InferCtx, mod_name: Str, uses: List<UseDecl>,
    decls: List<Decl>, required_effects: List<EffectExpr>?,
    is_pub: Bool, span: Span, project_frame_active: Bool,
    cached_impls: List<CachedImplClose>,
    cached_values: List<CachedValueClose>
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
        match prefixed {
            Decl::Fn { name, .. } => {
                let executable = value_callable_executable(ctx, name)
                let cached = cached_value_declaration(
                    cached_values, executable).unwrap_or_else(fn() {
                    panic("inline HIR cache: final function is absent")
                })
                hdecls.push(cached)
            },
            Decl::Impl { .. } => {
                let cached = cached_impl_declarations(
                    cached_impls,
                    impl_check_owner(ctx, decl_index)).unwrap_or_else(fn() {
                    panic("inline HIR cache: final impl is absent")
                })
                for value in cached {
                    hdecls.push(value)
                }
            },
            _ => {
                let result = some(check_decl(
                    ctx, prefixed, some(decl_index),
                    cached_impls, cached_values)) catch { _ => none }
                match result {
                    some(hdecl) => {
                        match cap_row {
                            some(capability) => check_capability(
                                ctx, hdecl, capability, span),
                            none => {}
                        }
                        hdecls.push(hdecl)
                    },
                    none => {}
                }
            }
        }
    }
    HDecl::ModBlock { name: mod_name, decls: hdecls, is_pub: is_pub, span: span }
}

fn check_mod_decl(
    mut ctx: InferCtx, mod_name: Str, uses: List<UseDecl>,
    decls: List<Decl>, required_effects: List<EffectExpr>?,
    is_pub: Bool, span: Span, frame_decl_index: Int?,
    cached_impls: List<CachedImplClose>,
    cached_values: List<CachedValueClose>
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
        is_pub, span, project_active,
        cached_impls, cached_values) catch { _ => {
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

fn cache_checked_impl_decl(
    mut ctx: InferCtx, decl: Decl, decl_index: Int,
    mut cached_impls: List<CachedImplClose>,
    validation: FnValidationContext
) {
    let owner_ref = impl_check_owner(ctx, decl_index)
    if cached_impl_declarations(cached_impls, owner_ref).is_some() {
        panic("impl close cache: exact owner was checked twice")
    }
    let hdecl = match decl {
        Decl::Impl {
            target_type, type_params, trait_name, methods, span
        } => check_impl_decl(
            ctx, target_type, type_params, trait_name, methods,
            span, decl_index, validation),
        _ => panic("impl close cache: source declaration is not an impl")
    }
    let mut declarations: List<HDecl> = [hdecl]
    match decl {
        Decl::Impl { methods, .. } => {
            for source_member_index in 0..methods.len() {
                match methods.get(source_member_index) {
                    some(Decl::Delegate { field, span, .. }) => {
                        let expanded = expand_delegate_impls(
                            ctx, hdecl, source_member_index, field, span,
                            validation)
                        for child in expanded { declarations.push(child) }
                    },
                    _ => {}
                }
            }
        },
        _ => panic("impl close cache: source declaration is not an impl")
    }
    cached_impls.push(CachedImplClose {
        owner_ref: owner_ref, declarations: declarations
    })
}

fn cache_inline_impls_in_mod_body(
    mut ctx: InferCtx, mod_name: Str, uses: List<UseDecl>,
    decls: List<Decl>, required_effects: List<EffectExpr>?,
    module_span: Span, project_frame_active: Bool,
    mut cached_impls: List<CachedImplClose>
) {
    if !project_frame_active {
        insert_mod_aliases(ctx, mod_name, decls, false)
        resolve_mod_uses(ctx, uses, true)
    }
    let capability = required_effects.map(fn(values) {
        resolve_declared_effects(ctx, values)
    })
    match capability {
        some(row) => {
            ctx.mod_unsafe_allowed = row.effects.any(fn(eff) {
                match eff {
                    Effect::UnsafeEffect => true,
                    _ => false
                }
            })
        },
        none => { ctx.mod_unsafe_allowed = false }
    }
    let validation = FnValidationContext {
        capability: capability,
        capability_span: capability.map(fn(_) { module_span })
    }

    for decl_index in 0..decls.len() {
        let prefixed = prefix_decl_name(
            mod_name, decls.get(decl_index).unwrap())
        match prefixed {
            Decl::Impl { .. } => cache_checked_impl_decl(
                ctx, prefixed, decl_index, cached_impls, validation),
            Decl::ModBlock {
                name, uses: nested_uses, decls: nested_decls,
                required_effects: nested_required, span: nested_span, ..
            } => cache_inline_impls_in_mod(
                ctx, name, nested_uses, nested_decls,
                nested_required, nested_span, decl_index, cached_impls),
            _ => {}
        }
    }
}

fn cache_inline_impls_in_mod(
    mut ctx: InferCtx, mod_name: Str, uses: List<UseDecl>,
    decls: List<Decl>, required_effects: List<EffectExpr>?,
    module_span: Span, frame_decl_index: Int,
    mut cached_impls: List<CachedImplClose>
) {
    enter_impl_check_child_frame(ctx, frame_decl_index)
    let project_active = ctx.project_namespace_file_key.is_some()
    let mut entered_project_frame = false
    if project_active {
        entered_project_frame = enter_project_child_frame(
            ctx, frame_decl_index)
        if !entered_project_frame {
            exit_impl_check_frame(ctx)
            panic("unreachable: resolver plan missing inline impl frame")
        }
    }
    let segments = mod_name.split("::")
    let simple_name = segments.get(segments.len() - 1).unwrap_or(mod_name)
    ctx.mod_path_stack.push(simple_name)
    let previous_unsafe = ctx.mod_unsafe_allowed
    let result = some(cache_inline_impls_in_mod_body(
        ctx, mod_name, uses, decls, required_effects,
        module_span, project_active, cached_impls)) catch { _ => none }
    ctx.mod_unsafe_allowed = previous_unsafe
    let _ = ctx.mod_path_stack.pop()
    if entered_project_frame {
        let _ = exit_project_namespace_frame(ctx)
    }
    exit_impl_check_frame(ctx)
    if result.is_none() { fail.raise(CompileError {}) }
}

fn prepare_impl_close_cache(
    mut ctx: InferCtx, decls: List<Decl>,
    mut cached_impls: List<CachedImplClose>
) {
    for decl_index in 0..decls.len() {
        match decls.get(decl_index).unwrap() {
            Decl::Impl { .. } => cache_checked_impl_decl(
                ctx, decls.get(decl_index).unwrap(), decl_index,
                cached_impls, FnValidationContext {
                    capability: none, capability_span: none
                }),
            Decl::ModBlock {
                name, uses, decls: mod_decls,
                required_effects, span, ..
            } => cache_inline_impls_in_mod(
                ctx, name, uses, mod_decls, required_effects,
                span, decl_index, cached_impls),
            _ => {}
        }
    }
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

fn build_final_callable_effect_schema(
    scheme: TypeScheme, executable: ExecutableRef,
    inherited_type_vars: List<Int>
) -> TypedEffectHeaderSchema {
    let mut owned_tails: List<Int> = []
    for tail in ordered_effect_tail_vars(scheme.ty) {
        if scheme.type_vars.contains(tail) &&
           !inherited_type_vars.contains(tail) {
            owned_tails.push(tail)
        }
    }
    if typed_effect_header_schema_bindings(
            scheme.effect_schema).len() > 0 || owned_tails.len() == 0 {
        scheme.effect_schema
    } else {
        build_definition_effect_header_schema(
            executable_effect_origin(executable), [scheme.ty],
            owned_tails)
    }
}

fn publish_final_value_effect_schema(
    mut ctx: InferCtx, name: Str, executable: ExecutableRef,
    callable_signature: Type
) -> TypedEffectHeaderSchema {
    let scheme = match ctx.env.lookup(name) {
        some(value) => value,
        none => panic("effect header schema: final value scheme is absent")
    }
    let schema = build_final_callable_effect_schema(
        scheme, executable, [])
    let final_scheme = TypeScheme { ..scheme, effect_schema: schema }
    validate_effect_header_schema(
        [final_scheme.ty], final_scheme.type_vars, schema)
    rebind_fn_scheme_with_alias(ctx, name, final_scheme)
    publish_exact_callable_effect_header(
        ctx, executable, callable_signature, schema)
    schema
}

fn check_const_decl(mut ctx: InferCtx, name: Str, type_annotation: TypeExpr?, init: Expr, is_pub: Bool, span: Span) -> HDecl {
    let batch_checkpoint = owner_batch_checkpoint(ctx)
    let saved_subst = ctx.subst
    ctx.subst = empty_subst()
    // Retrieve the def_id assigned during registration
    let old_def_id = match ctx.env.lookup(name) {
        some(sc) => sc.def_id,
        none => none
    }
    let const_executable = named_executable_for_def_id(
        ctx, old_def_id, "const '${name}'")
    enter_executable_owner(ctx, const_executable)
    let mut expected_ty: Type? = none
    match type_annotation {
        some(texpr) => { expected_ty = some(resolve_type_expr(ctx, texpr)) },
        none => {}
    }
    let init_r = match some(infer_expr(ctx, init, ctx.subst)) catch {
            _ => none } {
        some(value) => value,
        none => {
            rollback_owner_batch(ctx, batch_checkpoint)
            exit_executable_owner(ctx)
            ctx.subst = saved_subst
            fail.raise(CompileError {})
        }
    }
    let mut s = init_r.subst
    let mut init_ty = hexpr_type(init_r.hexpr)
    match expected_ty {
        some(ann_ty) => {
            s = unify_at(ctx.sink, ctx.env, init_ty, ann_ty, s, span)
            init_ty = apply_subst(s, ann_ty)
        },
        none => {}
    }
    let batch = detach_owner_batch(ctx, batch_checkpoint)
    let final_batch_unstaged = match some(
            drain_owner_batch_dictionaries(ctx, batch, s)) catch { _ => none } {
        some(value) => value,
        none => {
            rollback_owner_batch(ctx, batch_checkpoint)
            exit_executable_owner(ctx)
            ctx.subst = saved_subst
            fail.raise(CompileError {})
        }
    }
    // A const initializer is a value position.  Resolve its fully unified
    // function-value evidence before restoring the declaration substitution;
    // otherwise a bounded module function reaches codegen without its DictRef.
    let zctx = ZonkCtx {
        subst: s, names: map_new(),
        canonical_type_var_ids: map_new(),
        dict_resolver: none
    }
    let resolved = zonk_type(zctx, init_ty)
    let zonked_init = some(zonk_expr(zctx, init_r.hexpr)) catch { _ => none }
    let final_init_unremapped = match zonked_init {
        some(value) => value,
        none => {
            // Declaration-level recovery continues checking later declarations.
            // Never leak this const's isolated substitution through that path.
            rollback_owner_batch(ctx, batch_checkpoint)
            exit_executable_owner(ctx)
            ctx.subst = saved_subst
            fail.raise(CompileError {})
        }
    }
    let gen_scheme = generalize(ctx.env, resolved, s)
    // Preserve the original def_id so mutability checks work
    let scheme = TypeScheme { ty: gen_scheme.ty,
        type_vars: gen_scheme.type_vars, bounds: gen_scheme.bounds,
        effect_schema: gen_scheme.effect_schema, def_id: old_def_id }
    let effect_schema = build_final_callable_effect_schema(
        scheme, const_executable, [])
    let final_scheme = TypeScheme { ..scheme,
        effect_schema: effect_schema }
    validate_effect_header_schema(
        [final_scheme.ty], final_scheme.type_vars, effect_schema)
    let callable_signature = Type::FnType {
        params: [], return_type: resolved,
        effects: hexpr_effects(final_init_unremapped)
    }
    let final_batch = stage_owner_batch_facts(
        ctx, final_batch_unstaged, const_executable,
        callable_signature, effect_schema, s, map_new())
    let d1_checkpoint = ctx.sink.save()
    let final_init = finalize_effect_ctx_expr(
        ctx, FinalEffectCtxAuthority::FinalEffectCtxOwnerBatch(final_batch),
        final_init_unremapped)
    let effect_ctx = current_typed_callable_effect_ctx_from_owner_batch(
        ctx, final_batch, hexpr_effects(final_init))
    check_final_runtime_handled_contract(
        ctx, callable_signature, some(effect_ctx), name, span)
    if diagnostics_since_has_errors(ctx, d1_checkpoint) {
        rollback_owner_batch(ctx, batch_checkpoint)
        exit_executable_owner(ctx)
        ctx.subst = saved_subst
        fail.raise(CompileError {})
    }
    preflight_owner_batches(ctx, [final_batch])
    rebind_fn_scheme_with_alias(ctx, name, final_scheme)
    publish_owner_batches(ctx, [final_batch])
    exit_executable_owner(ctx)
    ctx.subst = saved_subst
    HDecl::Const { name: name, def_id: old_def_id,
        executable_ref: const_executable,
        effect_ctx: effect_ctx,
        ty: resolved, init: final_init, is_pub: is_pub, span: span }
}

fn record_nominal_core_parameters(
    mut ctx: InferCtx, owner: SymbolRef,
    type_params: List<TypeParam>, type_var_ids: List<Int>
) {
    if type_params.len() != type_var_ids.len() {
        panic("Core type producer: nominal parameter arity differs")
    }
    let mut index = 0
    while index < type_params.len() {
        let param = type_params.get(index).unwrap()
        let mut bounds: List<SymbolRef> = []
        for bound in param.bounds {
            let trait_name = resolve_trait_identity(ctx, bound.trait_name)
            let trait_def = ctx.env.trait_reg.traits.get(
                trait_name).unwrap_or_else(fn() {
                panic("Core type producer: nominal bound trait is missing")
            })
            bounds.push(registered_trait_ref_symbol(trait_def.owner_ref))
        }
        index = index + 1
    }
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
    record_nominal_core_parameters(
        ctx, registered_nominal_ref_symbol(def.owner_ref),
        type_params, def.type_param_vars)
    HDecl::Struct {
        name: name, owner_ref: def.owner_ref,
        type_params: exact_h_type_params(
            ctx, type_params, def.type_param_vars), fields: hfields,
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
    record_nominal_core_parameters(
        ctx, registered_nominal_ref_symbol(def.owner_ref),
        type_params, def.type_param_vars)
    HDecl::Enum {
        name: name, owner_ref: def.owner_ref,
        type_params: exact_h_type_params(
            ctx, type_params, def.type_param_vars), variants: hvariants,
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
            op_params.push(HParam { name: p_name, ty: pt,
                def_id: none, is_mutable: false })
            pi = pi + 1
        }
        hops.push(HEffectOp {
            name: op.name, operation_ref: op.operation_ref,
            params: op_params, return_type: op.return_type
        })
        oi = oi + 1
    }

    match def.owner_ref {
        some(owner) => record_nominal_core_parameters(
            ctx, owner, type_params, def.type_param_vars),
        none => if type_params.len() != 0 {
            panic("Core type producer: builtin effect has type parameters")
        }
    }
    HDecl::Effect {
        name: name, owner_ref: def.owner_ref, handled_ref: def.handled_ref,
        type_params: exact_h_type_params(
            ctx, type_params, def.type_param_vars),
        ops: hops, is_pub: is_pub, span: span
    }
}

fn registered_impl_method_scheme(
    ctx: InferCtx, target_type: Str,
    owner_ref: ImplOwnerRef, method_name: Str
) -> TypeScheme? {
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
    mut ctx: InferCtx, target_type: Str,
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
    let core = impl_method_core_from_scheme(scheme)
    replace_impl_method_core(
        ctx.env.trait_reg, target_type, owner_ref, method_name, core)
    let installed = install_method_core(
        ctx.env.trait_reg, ctx.sink,
        target_type, method_name, core,
        owner.method_refs.get(method_name).unwrap(), span)
    if !installed {
        panic("impl method commit: preflighted method index changed")
    }
}

fn infer_impl_method_draft(
    mut ctx: InferCtx, target_type: Str,
    impl_owner: ImplEntry, impl_self_type: Type, method: Decl,
    validation: FnValidationContext
) -> FnDraft {
    match method {
        Decl::Fn {
            name, type_params, params, return_type,
            declared_effects, body, is_pub, span, ..
        } => {
            let registration_scheme = registered_impl_method_scheme(
                ctx, target_type,
                impl_owner.owner_ref.unwrap(), name).unwrap_or_else(fn() {
                panic("impl method draft: registration scheme is absent")
            })
            let exact_method = impl_owner.method_refs.get(
                name).unwrap_or_else(fn() {
                panic("impl method draft: exact identity is absent")
            })
            infer_fn_draft(
                ctx, name, type_params, params, return_type,
                declared_effects, body, is_pub, span,
                some(impl_self_type), some(registration_scheme),
                some(symbol_ref_declaration_site_path(
                    impl_method_ref_member(exact_method))),
                some(exact_method), impl_owner.type_param_vars,
                validation)
        },
        _ => panic("impl method draft: member is not a function")
    }
}
fn draft_canonical_type_var_ids(
    draft: FnDraft, frozen_subst: UnionFind
) -> Map<Int, Int> {
    let mut result: Map<Int, Int> = map_new()
    let declared_count = draft.inherited_type_var_ids.len() +
        draft.source_type_var_ids.len()
    for index in 0..declared_count {
        let source = draft.registration_scheme.type_vars.get(index).unwrap()
        let canonical = if index < draft.inherited_type_var_ids.len() {
            draft.inherited_type_var_ids.get(index).unwrap()
        } else {
            draft.source_type_var_ids.get(
                index - draft.inherited_type_var_ids.len()).unwrap()
        }
        match apply_subst(
                frozen_subst,
                Type::TypeVar { id: source, name: none }) {
            Type::TypeVar { id: representative, .. } =>
                insert_canonical_type_var_id(
                    result, representative, canonical),
            _ => {}
        }
        match apply_subst(
                frozen_subst,
                Type::TypeVar { id: canonical, name: none }) {
            Type::TypeVar { id: representative, .. } =>
                insert_canonical_type_var_id(
                    result, representative, canonical),
            _ => {}
        }
    }
    result
}

fn draft_type_var_names(
    draft: FnDraft, frozen_subst: UnionFind
) -> Map<Int, Str> {
    let mut result: Map<Int, Str> = map_new()
    for entry in draft.raw_type_var_names.entries() {
        let (raw_id, name) = entry
        match apply_subst(
                frozen_subst,
                Type::TypeVar { id: raw_id, name: none }) {
            Type::TypeVar { id, .. } => result.insert(id, name),
            _ => {}
        }
    }
    result
}

fn canonical_draft_type_var_id(
    source: Int, canonical_ids: Map<Int, Int>,
    frozen_subst: UnionFind
) -> Int {
    match apply_subst(
            frozen_subst,
            Type::TypeVar { id: source, name: none }) {
        Type::TypeVar { id, .. } => canonical_ids.get(id).unwrap_or(id),
        _ => source
    }
}

fn stage_fn_draft_scheme(
    mut ctx: InferCtx, draft: FnDraft,
    frozen_subst: UnionFind, external_free: Set<Int>
) -> StagedCallableClose {
    let canonical_ids = draft_canonical_type_var_ids(
        draft, frozen_subst)
    let zctx = ZonkCtx {
        subst: frozen_subst,
        names: draft_type_var_names(draft, frozen_subst),
        canonical_type_var_ids: canonical_ids,
        dict_resolver: none
    }
    let final_type = zonk_type(zctx, draft.registration_scheme.ty)
    let mut type_vars: List<Int> = []
    for source in draft.registration_scheme.type_vars {
        match apply_subst(
                frozen_subst,
                Type::TypeVar { id: source, name: none }) {
            Type::TypeVar { id, .. } => {
                let canonical = canonical_ids.get(id).unwrap_or(id)
                if !type_vars.contains(canonical) {
                    type_vars.push(canonical)
                }
            },
            _ => {}
        }
    }
    let mut final_free = free_type_vars(
        final_type, empty_subst()).to_list()
    final_free.sort()
    for id in final_free {
        if !type_vars.contains(id) && !external_free.contains(id) {
            type_vars.push(id)
        }
    }

    let mut bounds: List<SchemeBound> = []
    for bound in draft.registration_scheme.bounds {
        let subject = canonical_draft_type_var_id(
            bound.type_var, canonical_ids, frozen_subst)
        let mut constraints: List<AssocConstraintEntry> = []
        for constraint in bound.assoc_constraints {
            constraints.push(AssocConstraintEntry {
                name: constraint.name,
                ty: zonk_type(zctx, constraint.ty)
            })
        }
        bounds.push(SchemeBound {
            type_var: subject,
            trait_name: bound.trait_name,
            assoc_constraints: constraints
        })
    }
    for id in type_vars {
        match ctx.env.scope.var_bounds.get(id) {
            some(traits) => {
                let mut ordered = traits.to_list()
                ordered.sort()
                for trait_name in ordered {
                    if !bounds.any(fn(bound) {
                            bound.type_var == id &&
                            bound.trait_name == trait_name
                        }) {
                        bounds.push(SchemeBound {
                            type_var: id,
                            trait_name: trait_name,
                            assoc_constraints: []
                        })
                    }
                }
            },
            none => {}
        }
    }
    let provisional = TypeScheme {
        ty: final_type, type_vars: type_vars, bounds: bounds,
        effect_schema: draft.registration_scheme.effect_schema,
        def_id: draft.registration_scheme.def_id
    }
    let schema = build_final_callable_effect_schema(
        provisional, draft.executable,
        draft.inherited_type_var_ids)
    let scheme = TypeScheme { ..provisional, effect_schema: schema }
    let quantified = scheme.type_vars.filter(fn(id) {
        !draft.inherited_type_var_ids.contains(id)
    })
    validate_effect_header_schema([scheme.ty], quantified, schema)
    StagedCallableClose {
        name: draft.name,
        executable: draft.executable,
        scheme: scheme,
        span: draft.span
    }
}

fn report_open_runtime_handled_instance(
    mut ctx: InferCtx, carrier: Str, span: Span
) {
    let _ = type_error(
        ctx.sink, E0404,
        "Runtime handled effect instance in '${carrier}' must use fully closed type arguments",
        span, DiagnosticContext::OtherContext { detail: some(
            "instantiate the custom effect with closed type arguments before perform or handle") })
}

fn callable_effect_ctx_is_fully_closed(
    value: TypedCallableEffectCtx
) -> Bool {
    typed_effect_ctx_layout_entries(
        typed_callable_effect_ctx_layout(value)).all(fn(instance) {
            typed_handled_effect_instance_is_fully_closed(instance)
        })
}

fn check_final_runtime_handled_contract(
    mut ctx: InferCtx, header: Type, effect_ctx: TypedCallableEffectCtx?,
    carrier: Str, span: Span
) {
    let context_closed = match effect_ctx {
        some(value) => callable_effect_ctx_is_fully_closed(value),
        none => true
    }
    if !typed_callable_header_has_closed_handled_instances(header) ||
       !context_closed {
        report_open_runtime_handled_instance(ctx, carrier, span)
    }
}

fn callable_type_actuals_are_fully_closed(
    values: List<HCallableTypeActual>
) -> Bool {
    values.all(fn(value) {
        typed_runtime_actual_type_has_closed_handled_instances(value.actual)
    })
}

fn callable_effect_instantiation_is_fully_closed(
    value: HCallableEffectInstantiation?
) -> Bool {
    match value {
        some(instantiation) => instantiation.substitutions.all(fn(actual) {
            typed_runtime_effect_actual_has_closed_handled_instances(
                actual.actual)
        }),
        none => true
    }
}

fn callable_value_instantiation_is_fully_closed(
    value: HCallableValueInstantiation?
) -> Bool {
    match value {
        some(instantiation) =>
            callable_type_actuals_are_fully_closed(
                instantiation.type_args) &&
            callable_effect_instantiation_is_fully_closed(
                instantiation.effects),
        none => true
    }
}

fn finalize_call_effect_ctx(
    existing: TypedEffectCtxSource, callable: Type
) -> TypedEffectCtxSource {
    let effects = match callable {
        Type::FnType { effects, .. } => effects,
        _ => panic("effect context finalization: call target is not callable")
    }
    let requires_ctx =
        typed_handled_effect_instances_from_row(effects).len() != 0 ||
        effects.tail.is_some()
    if !requires_ctx { return make_empty_effect_ctx_source() }
    if typed_effect_ctx_source_is_empty(existing) {
        panic("effect context finalization: effectful call lost current context")
    }
    existing
}

enum FinalEffectCtxAuthority {
    FinalEffectCtxOwnerBatch(OwnerInferenceBatch),
    FinalEffectCtxHeader(TypedEffectHeaderSchema)
}

fn finalized_callable_effect_ctx_layout(
    ctx: InferCtx, authority: FinalEffectCtxAuthority, row: EffectRow
) -> TypedEffectCtxLayout {
    match authority {
        FinalEffectCtxAuthority::FinalEffectCtxOwnerBatch(owner_batch) =>
            typed_effect_ctx_layout_from_owner_batch(
            ctx, owner_batch, row),
        FinalEffectCtxAuthority::FinalEffectCtxHeader(schema) => {
            let represented = match row.tail {
                some(raw_tail) => typed_effect_header_schema_bindings(
                    schema).any(fn(binding) {
                        typed_effect_header_binding_raw_tail(binding) ==
                            raw_tail
                    }),
                none => true
            }
            if represented {
                typed_effect_ctx_layout_for_row(row, schema)
            } else {
                typed_effect_ctx_layout_from_published_schema(ctx, row)
            }
        }
    }
}

fn finalize_effect_ctx_match_arms(
    mut ctx: InferCtx, batch: FinalEffectCtxAuthority,
    values: List<HMatchArm>
) -> List<HMatchArm> {
    values.map(fn(value) { HMatchArm {
        pattern: value.pattern, pattern_plan: value.pattern_plan,
        bindings: value.bindings,
        guard: value.guard.map(fn(expr) {
            finalize_effect_ctx_expr(ctx, batch, expr)
        }),
        body: finalize_effect_ctx_expr(ctx, batch, value.body),
        span: value.span
    } })
}

fn finalize_effect_ctx_captures(
    mut ctx: InferCtx, batch: FinalEffectCtxAuthority,
    values: List<HLambdaCapture>
) -> List<HLambdaCapture> {
    values.map(fn(value) { HLambdaCapture {
        source: value.source, target: value.target,
        value: value.value.map(fn(expr) {
            finalize_effect_ctx_expr(ctx, batch, expr)
        }),
        resource_site: value.resource_site
    } })
}

fn finalize_effect_ctx_stmt(
    mut ctx: InferCtx, batch: FinalEffectCtxAuthority, value: HStmt
) -> HStmt {
    match value {
        HStmt::Let { name, name_span, def_id, ty, init, span } =>
            HStmt::Let { name: name, name_span: name_span,
                def_id: def_id, ty: ty,
                init: finalize_effect_ctx_expr(ctx, batch, init),
                span: span },
        HStmt::Var { name, name_span, def_id, ty, init, span } =>
            HStmt::Var { name: name, name_span: name_span,
                def_id: def_id, ty: ty,
                init: finalize_effect_ctx_expr(ctx, batch, init),
                span: span },
        HStmt::Assign { target, value, span } => HStmt::Assign {
            target: finalize_effect_ctx_expr(ctx, batch, target),
            value: finalize_effect_ctx_expr(ctx, batch, value),
            span: span },
        HStmt::ExprStmt { expr, span } => HStmt::ExprStmt {
            expr: finalize_effect_ctx_expr(ctx, batch, expr), span: span },
        HStmt::Return { value, span } => HStmt::Return {
            value: value.map(fn(expr) {
                finalize_effect_ctx_expr(ctx, batch, expr)
            }), span: span },
        HStmt::While { condition, body, span } => HStmt::While {
            condition: finalize_effect_ctx_expr(ctx, batch, condition),
            body: finalize_effect_ctx_expr(ctx, batch, body), span: span },
        HStmt::ForIn {
            binding, binding_span, def_id, destructure, plan,
            iterable, body, iterable_type_name, iter_type_name, span
        } => HStmt::ForIn {
            binding: binding, binding_span: binding_span,
            def_id: def_id, destructure: destructure, plan: plan,
            iterable: finalize_effect_ctx_expr(ctx, batch, iterable),
            body: finalize_effect_ctx_expr(ctx, batch, body),
            iterable_type_name: iterable_type_name,
            iter_type_name: iter_type_name, span: span },
        HStmt::Break { span } => HStmt::Break { span: span },
        HStmt::Continue { span } => HStmt::Continue { span: span },
        HStmt::LetDestructure {
            pattern, pattern_plan, bindings, init, span
        } => HStmt::LetDestructure {
            pattern: pattern, pattern_plan: pattern_plan,
            bindings: bindings,
            init: finalize_effect_ctx_expr(ctx, batch, init), span: span },
        HStmt::IfLet {
            pattern, pattern_plan, bindings, expr,
            then_block, else_block, span
        } => HStmt::IfLet {
            pattern: pattern, pattern_plan: pattern_plan,
            bindings: bindings,
            expr: finalize_effect_ctx_expr(ctx, batch, expr),
            then_block: finalize_effect_ctx_expr(ctx, batch, then_block),
            else_block: else_block.map(fn(branch) {
                finalize_effect_ctx_expr(ctx, batch, branch)
            }), span: span },
        HStmt::Drop {
            name, def_id, slot, place_target, site, reason, ty, span
        } => HStmt::Drop { name: name, def_id: def_id, slot: slot,
            place_target: place_target.map(fn(expr) {
                finalize_effect_ctx_expr(ctx, batch, expr)
            }), site: site, reason: reason, ty: ty, span: span }
    }
}

fn finalize_effect_ctx_handler(
    mut ctx: InferCtx, batch: FinalEffectCtxAuthority,
    handler: HEffectHandler
) -> HEffectHandler {
    let final_effect_ctx = make_typed_callable_effect_ctx(
        typed_callable_effect_ctx_binding(handler.effect_ctx),
        finalized_callable_effect_ctx_layout(
            ctx, batch, hexpr_effects(handler.body)))
    let final_body = finalize_effect_ctx_expr(
        ctx, batch, handler.body)
    let mut header_params = handler.params.map(fn(param) { param.ty })
    match handler.resume_binding {
        some(binding) => header_params.push(binding.ty),
        none => {}
    }
    let header = Type::FnType {
        params: header_params, return_type: hexpr_type(final_body),
        effects: hexpr_effects(final_body)
    }
    let handled_closed = match handler.handled_instance {
        some(instance) =>
            typed_handled_effect_instance_is_fully_closed(instance),
        none => true
    }
    if !handled_closed ||
       !typed_callable_header_has_closed_handled_instances(header) ||
       !callable_effect_ctx_is_fully_closed(final_effect_ctx) {
        report_open_runtime_handled_instance(
            ctx, "handler ${handler.effect_name}.${handler.op_name}",
            hexpr_span(final_body))
    }
    HEffectHandler {
        effect_name: handler.effect_name,
        handled_instance: handler.handled_instance,
        operation_ref: handler.operation_ref,
        fail_ref: handler.fail_ref,
        executable_ref: handler.executable_ref,
        captures: finalize_effect_ctx_captures(
            ctx, batch, handler.captures),
        effect_ctx: final_effect_ctx,
        parent_ctx: handler.parent_ctx,
        op_name: handler.op_name, params: handler.params,
        resume_binding: handler.resume_binding,
        body: final_body
    }
}

fn finalize_effect_ctx_expr(
    mut ctx: InferCtx, batch: FinalEffectCtxAuthority, value: HExpr
) -> HExpr {
    match value {
        HExpr::Call {
            callee, args, type_args, effect_instantiation,
            resolved_dicts, effect_ctx, callee_ref,
            method_ref, system_host, ty, effects, span
        } => {
            let callee = match callee {
                HExpr::Ident { .. } =>
                    finalize_direct_callee_no_solve(ctx, callee),
                _ => finalize_effect_ctx_expr(ctx, batch, callee)
            }
            let callee_value_closed = match callee {
                HExpr::Ident { callable_instantiation, .. } =>
                    callable_value_instantiation_is_fully_closed(
                        callable_instantiation),
                _ => true
            }
            if !typed_callable_header_has_closed_handled_instances(
                    hexpr_type(callee)) ||
               !callable_type_actuals_are_fully_closed(type_args) ||
               !callable_effect_instantiation_is_fully_closed(
                    effect_instantiation) ||
               !callee_value_closed {
                report_open_runtime_handled_instance(ctx, "call", span)
            }
            HExpr::Call {
                callee: callee,
                args: args.map(fn(arg) {
                    finalize_effect_ctx_expr(ctx, batch, arg)
                }),
                type_args: type_args,
                effect_instantiation: effect_instantiation,
                resolved_dicts: resolved_dicts,
                effect_ctx: finalize_call_effect_ctx(
                    effect_ctx, hexpr_type(callee)),
                callee_ref: callee_ref, method_ref: method_ref,
                system_host: system_host,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::EffectOp {
            effect_name, op_name, operation_ref, fail_ref,
            effect_ctx_lookup, args, ty, effects, span
        } => {
            match effect_ctx_lookup {
                some(lookup) => if
                        !typed_handled_effect_instance_is_fully_closed(
                            typed_effect_ctx_lookup_instance(lookup)) {
                    report_open_runtime_handled_instance(
                        ctx, "effect operation ${effect_name}.${op_name}",
                        span)
                },
                none => {}
            }
            HExpr::EffectOp {
                effect_name: effect_name, op_name: op_name,
                operation_ref: operation_ref, fail_ref: fail_ref,
                effect_ctx_lookup: effect_ctx_lookup,
                args: args.map(fn(arg) {
                    finalize_effect_ctx_expr(ctx, batch, arg)
                }), ty: ty, effects: effects, span: span
            }
        },
        HExpr::HandleExpr {
            body, handlers, effect_ctx_install, ty, effects, span
        } => {
            match effect_ctx_install {
                some(install) => if !typed_effect_ctx_install_entries(
                        install).all(fn(instance) {
                            typed_handled_effect_instance_is_fully_closed(
                                instance)
                        }) {
                    report_open_runtime_handled_instance(
                        ctx, "handle", span)
                },
                none => {}
            }
            HExpr::HandleExpr {
                body: finalize_effect_ctx_expr(ctx, batch, body),
                handlers: handlers.map(fn(handler) {
                    finalize_effect_ctx_handler(ctx, batch, handler)
                }),
                effect_ctx_install: effect_ctx_install,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::Lambda {
            executable_ref, params, captures, effect_ctx,
            return_type, body, ty, effects, span
        } => {
            let callable_effects = match ty {
                Type::FnType { effects, .. } => effects,
                _ => panic("effect context finalization: lambda is not callable")
            }
            let final_effect_ctx = make_typed_callable_effect_ctx(
                typed_callable_effect_ctx_binding(effect_ctx),
                finalized_callable_effect_ctx_layout(
                    ctx, batch, callable_effects))
            let final_body = finalize_effect_ctx_expr(ctx, batch, body)
            if !typed_callable_header_has_closed_handled_instances(ty) ||
               !callable_effect_ctx_is_fully_closed(final_effect_ctx) {
                report_open_runtime_handled_instance(ctx, "lambda", span)
            }
            HExpr::Lambda {
                executable_ref: executable_ref, params: params,
                captures: finalize_effect_ctx_captures(
                    ctx, batch, captures),
                effect_ctx: final_effect_ctx,
                return_type: return_type,
                body: final_body,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::BinOp {
            op, left, right, eq_dispatch, ord_dispatch,
            eq_plan, ord_plan, ty, effects, span
        } => HExpr::BinOp { op: op,
            left: finalize_effect_ctx_expr(ctx, batch, left),
            right: finalize_effect_ctx_expr(ctx, batch, right),
            eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
            eq_plan: eq_plan, ord_plan: ord_plan,
            ty: ty, effects: effects, span: span },
        HExpr::UnaryOp { op, operand, ty, effects, span } =>
            HExpr::UnaryOp { op: op,
                operand: finalize_effect_ctx_expr(ctx, batch, operand),
                ty: ty, effects: effects, span: span },
        HExpr::FieldAccess {
            receiver, field, access_kind, projection, ty, effects, span
        } => HExpr::FieldAccess {
            receiver: finalize_effect_ctx_expr(ctx, batch, receiver),
            field: field, access_kind: access_kind,
            projection: projection,
            ty: ty, effects: effects, span: span },
        HExpr::StructLit {
            name, owner_ref, type_args, fields, spread, constructor,
            ty, effects, span
        } => HExpr::StructLit {
            name: name, owner_ref: owner_ref, type_args: type_args,
            fields: fields.map(fn(field) { HNominalStructFieldInit {
                name: field.name, field_ref: field.field_ref,
                field_index: field.field_index,
                value: finalize_effect_ctx_expr(ctx, batch, field.value)
            } }),
            spread: spread.map(fn(expr) {
                finalize_effect_ctx_expr(ctx, batch, expr)
            }), constructor: constructor,
            ty: ty, effects: effects, span: span },
        HExpr::NamedVariantConstruct {
            enum_name, variant_name, variant_ref, fields, spread,
            constructor, ty, effects, span
        } => HExpr::NamedVariantConstruct {
            enum_name: enum_name, variant_name: variant_name,
            variant_ref: variant_ref,
            fields: fields.map(fn(field) { HStructFieldInit {
                name: field.name, field_ref: field.field_ref,
                value: finalize_effect_ctx_expr(ctx, batch, field.value)
            } }),
            spread: spread.map(fn(expr) {
                finalize_effect_ctx_expr(ctx, batch, expr)
            }), constructor: constructor,
            ty: ty, effects: effects, span: span },
        HExpr::MatchExpr { scrutinee, arms, ty, effects, span } =>
            HExpr::MatchExpr {
                scrutinee: finalize_effect_ctx_expr(
                    ctx, batch, scrutinee),
                arms: finalize_effect_ctx_match_arms(ctx, batch, arms),
                ty: ty, effects: effects, span: span },
        HExpr::Block { stmts, tail, ty, effects, span } =>
            HExpr::Block {
                stmts: stmts.map(fn(stmt) {
                    finalize_effect_ctx_stmt(ctx, batch, stmt)
                }),
                tail: tail.map(fn(expr) {
                    finalize_effect_ctx_expr(ctx, batch, expr)
                }), ty: ty, effects: effects, span: span },
        HExpr::IfExpr {
            condition, then_branch, else_branch, ty, effects, span
        } => HExpr::IfExpr {
            condition: finalize_effect_ctx_expr(
                ctx, batch, condition),
            then_branch: finalize_effect_ctx_expr(
                ctx, batch, then_branch),
            else_branch: else_branch.map(fn(expr) {
                finalize_effect_ctx_expr(ctx, batch, expr)
            }), ty: ty, effects: effects, span: span },
        HExpr::StringInterp { parts, plan, ty, effects, span } =>
            HExpr::StringInterp {
                parts: parts.map(fn(part) { match part {
                    HStringInterpPart::Literal(text) =>
                        HStringInterpPart::Literal(text),
                    HStringInterpPart::Expression(expr) =>
                        HStringInterpPart::Expression(
                            finalize_effect_ctx_expr(ctx, batch, expr))
                } }), plan: plan,
                ty: ty, effects: effects, span: span },
        HExpr::TryCatch { body, arms, ty, effects, span } =>
            HExpr::TryCatch {
                body: finalize_effect_ctx_expr(ctx, batch, body),
                arms: finalize_effect_ctx_match_arms(ctx, batch, arms),
                ty: ty, effects: effects, span: span },
        HExpr::ListLit { elements, plan, ty, effects, span } =>
            HExpr::ListLit {
                elements: elements.map(fn(expr) {
                    finalize_effect_ctx_expr(ctx, batch, expr)
                }), plan: plan,
                ty: ty, effects: effects, span: span },
        HExpr::TupleLit { elements, constructor, ty, effects, span } =>
            HExpr::TupleLit {
                elements: elements.map(fn(expr) {
                    finalize_effect_ctx_expr(ctx, batch, expr)
                }), constructor: constructor,
                ty: ty, effects: effects, span: span },
        HExpr::IndexExpr {
            receiver, index, call_plan, projection, ty, effects, span
        } => HExpr::IndexExpr {
            receiver: finalize_effect_ctx_expr(ctx, batch, receiver),
            index: finalize_effect_ctx_expr(ctx, batch, index),
            call_plan: call_plan, projection: projection,
            ty: ty, effects: effects, span: span },
        HExpr::Clone { inner, ty, effects, span } => HExpr::Clone {
            inner: finalize_effect_ctx_expr(ctx, batch, inner),
            ty: ty, effects: effects, span: span },
        HExpr::Take {
            source, source_slot, saved_slot, site, ty, effects, span
        } => HExpr::Take {
            source: finalize_effect_ctx_expr(ctx, batch, source),
            source_slot: source_slot, saved_slot: saved_slot,
            site: site, ty: ty, effects: effects, span: span },
        HExpr::ReturnExpr { value, ty, effects, span } =>
            HExpr::ReturnExpr {
                value: value.map(fn(expr) {
                    finalize_effect_ctx_expr(ctx, batch, expr)
                }), ty: ty, effects: effects, span: span },
        HExpr::UnsafeBlock { body, ty, effects, span } =>
            HExpr::UnsafeBlock {
                body: finalize_effect_ctx_expr(ctx, batch, body),
                ty: ty, effects: effects, span: span },
        HExpr::Ident { .. } => {
            let finalized = finalize_value_ident_no_solve(ctx, value)
            match finalized {
                HExpr::Ident { callable_instantiation, ty, span, .. } => if
                        !callable_value_instantiation_is_fully_closed(
                            callable_instantiation) ||
                        !typed_runtime_actual_type_has_closed_handled_instances(
                            ty) {
                    report_open_runtime_handled_instance(
                        ctx, "callable value", span)
                },
                _ => panic("effect context finalization: Ident changed kind")
            }
            finalized
        },
        HExpr::IntLit { .. } |
        HExpr::FloatLit { .. } |
        HExpr::StrLit { .. } |
        HExpr::BoolLit { .. } |
        HExpr::DictConstruct { .. } => value
    }
}

struct FinalDraftEffectCtx {
    body: HExpr,
    effect_ctx: TypedCallableEffectCtx
}

fn finalize_draft_effect_ctx(
    mut ctx: InferCtx, draft: FnDraft, batch: OwnerInferenceBatch,
    body: HExpr, final_effects: EffectRow
) -> FinalDraftEffectCtx {
    enter_executable_owner(ctx, draft.executable)
    let result = some(FinalDraftEffectCtx {
        body: finalize_effect_ctx_expr(
            ctx, FinalEffectCtxAuthority::FinalEffectCtxOwnerBatch(batch),
            body),
        effect_ctx: current_typed_callable_effect_ctx_from_owner_batch(
            ctx, batch, final_effects)
    }) catch { _ => none }
    exit_executable_owner(ctx)
    match result {
        some(value) => value,
        none => fail.raise(CompileError {})
    }
}

fn validate_draft_assoc_sources(
    mut ctx: InferCtx, draft: FnDraft, zctx: ZonkCtx,
    final_effects: EffectRow
) {
    for source in draft.assoc_rebind_sources {
        let checked = zonk_type(zctx, source.check_type)
        let represented = match source.registration_type {
            some(value) => types_equal(
                checked, zonk_type(zctx, value)),
            none => false
        }
        if !represented {
            let mut escapes = false
            for eff in final_effects.effects {
                match eff {
                    Effect::FailEffect { error_type } => {
                        if type_contains_exact(error_type, checked) {
                            escapes = true
                        }
                    },
                    _ => {}
                }
            }
            if escapes {
                let trait_display = nominal_display_name(source.trait_name)
                let detail = "associated type '${source.owner_name}::${source.assoc_name} (${trait_display})' has no exact registration representation"
                let _ = type_error(ctx.sink, E0503,
                    "Cannot finalize fail payload in '${nominal_display_name(draft.name)}': ${detail}",
                    draft.span,
                    DiagnosticContext::TraitError { detail: detail })
            }
        }
    }
}

fn finalize_fn_draft(
    mut ctx: InferCtx, draft: FnDraft,
    frozen_subst: UnionFind, canonical_ids: Map<Int, Int>,
    final_scheme: TypeScheme, final_batch: OwnerInferenceBatch
) -> HDecl {
    let zctx = ZonkCtx {
        subst: frozen_subst,
        names: draft_type_var_names(draft, frozen_subst),
        canonical_type_var_ids: canonical_ids,
        dict_resolver: none
    }
    let final_params = draft.params.map(fn(param) {
        zonk_param(zctx, param)
    })
    let final_return = zonk_type(zctx, draft.expected_return)
    let final_effects = zonk_row(zctx, draft.owner_effects)
    let zonked_body = zonk_block(zctx, draft.body)
    validate_draft_assoc_sources(
        ctx, draft, zctx, final_effects)
    let effect_ctx = finalize_draft_effect_ctx(
        ctx, draft, final_batch, zonked_body, final_effects)

    if draft.name == "main" || draft.name.ends_with("$$_main") {
        for eff in final_effects.effects {
            match eff {
                Effect::CustomEffect { name, .. } => {
                    let display = nominal_display_name(name)
                    let notes: List<DiagnosticNote> = [
                        DiagnosticNote {
                            message: "effect '${display}' is used but not handled in main",
                            span: some(draft.span)
                        },
                        DiagnosticNote {
                            message: "handle the effect before returning from main",
                            span: none
                        }
                    ]
                    let _ = type_error_with_notes(
                        ctx.sink, E0403,
                        "Unhandled effect '${display}' in main function; custom effects must be handled before reaching main",
                        draft.span,
                        DiagnosticContext::EffectUnhandled {
                            eff: display, in_function: some("main")
                        }, notes)
                },
                _ => {}
            }
        }
    }
    match (draft.validation.capability,
           draft.validation.capability_span) {
        (some(capability), some(capability_span)) =>
            check_effects_capability(
                ctx, draft.name, final_effects,
                capability, capability_span),
        (none, none) => {},
        _ => panic("function validation: capability context is incomplete")
    }

    let assembled_signature = Type::FnType {
        params: final_params.map(fn(parameter) { parameter.ty }),
        return_type: final_return, effects: final_effects
    }
    if !types_equal(assembled_signature, final_scheme.ty) {
        panic("function finalization: HIR signature differs from scheme")
    }
    check_final_runtime_handled_contract(
        ctx, assembled_signature, some(effect_ctx.effect_ctx),
        draft.name, draft.span)

    let mut mut_flags: List<Bool> = []
    for parameter in final_params {
        mut_flags.push(
            parameter.name != "self" && parameter.is_mutable &&
            is_value_type(parameter.ty))
    }
    journal_fn_mut_params_set(ctx, draft.name, mut_flags)
    match final_scheme.def_id {
        some(def_id) => journal_record_def_span(
            ctx, def_id, draft.span),
        none => {}
    }
    HDecl::Fn {
        name: draft.name,
        def_id: final_scheme.def_id,
        executable_ref: draft.executable,
        impl_method_ref: draft.impl_method_ref,
        type_params: draft.type_params,
        params: final_params,
        return_type: final_return,
        effects: final_effects,
        effect_ctx: effect_ctx.effect_ctx,
        body: effect_ctx.body,
        is_pub: draft.is_pub,
        trait_bounds: draft.trait_bounds,
        span: draft.span
    }
}

struct PreparedFnDraftGroup {
    declarations: List<HDecl>,
    staged: List<StagedCallableClose>,
    batches: List<OwnerInferenceBatch>
}

fn prepare_fn_draft_group(
    mut ctx: InferCtx, mut drafts: List<FnDraft>,
    executables: List<ExecutableRef>, diagnostic_checkpoint: Int
) -> PreparedFnDraftGroup {
    if diagnostics_since_has_errors(ctx, diagnostic_checkpoint) {
        fail.raise(CompileError {})
    }

    let mut batch_inputs: List<OwnerInferenceBatch> = []
    for draft in drafts { batch_inputs.push(draft.batch) }
    let drained = some(drain_owner_batch_dictionary_group(
        ctx, batch_inputs, ctx.subst)) catch { _ => none }
    let drained_batches = match drained {
        some(values) => values,
        none => fail.raise(CompileError {})
    }
    if drained_batches.len() != drafts.len() {
        panic("function draft group: dictionary batch census differs")
    }
    for index in 0..drafts.len() {
        let mut draft = drafts.get(index).unwrap()
        draft.batch = drained_batches.get(index).unwrap()
        drafts.set(index, draft)
    }
    if diagnostics_since_has_errors(ctx, diagnostic_checkpoint) {
        fail.raise(CompileError {})
    }

    let resolved_subst = ctx.subst
    let external_free = free_type_vars_outside_recursive_group(
        ctx, executables, resolved_subst)
    let mut staged: List<StagedCallableClose> = []
    for draft in drafts {
        staged.push(stage_fn_draft_scheme(
            ctx, draft, resolved_subst, external_free))
    }
    let mut headers: List<CallableFinalizationHeader> = []
    for index in 0..staged.len() {
        headers.push(make_callable_finalization_header(
            drafts.get(index).unwrap().executable,
            staged.get(index).unwrap().scheme))
    }
    for index in 0..drafts.len() {
        let mut draft = drafts.get(index).unwrap()
        draft.batch = project_owner_batch_receipts(
            draft.batch, headers)
        drafts.set(index, draft)
    }

    // Receipt projection is the final non-zonk operation. No inference or UF
    // mutation is permitted after this alias is taken.
    let frozen_subst = ctx.subst
    let mut declarations: List<HDecl> = []
    let mut batches: List<OwnerInferenceBatch> = []
    for index in 0..drafts.len() {
        let draft = drafts.get(index).unwrap()
        let final_scheme = staged.get(index).unwrap().scheme
        let canonical_ids = draft_canonical_type_var_ids(
            draft, frozen_subst)
        let final_batch = stage_owner_batch_facts(
            ctx, draft.batch, draft.executable,
            final_scheme.ty, final_scheme.effect_schema,
            frozen_subst, canonical_ids)
        declarations.push(finalize_fn_draft(
            ctx, draft, frozen_subst, canonical_ids,
            final_scheme, final_batch))
        batches.push(final_batch)
    }
    if diagnostics_since_has_errors(ctx, diagnostic_checkpoint) {
        fail.raise(CompileError {})
    }
    if declarations.len() != executables.len() ||
       staged.len() != executables.len() ||
       batches.len() != executables.len() {
        panic("function draft group: final artifact census differs")
    }
    for index in 0..executables.len() {
        if !executable_ref_same(
                staged.get(index).unwrap().executable,
                executables.get(index).unwrap()) {
            panic("function draft group: final executable order changed")
        }
    }
    preflight_owner_batches(ctx, batches)
    PreparedFnDraftGroup {
        declarations: declarations,
        staged: staged,
        batches: batches
    }
}

fn commit_value_draft_group(
    mut ctx: InferCtx, prepared: PreparedFnDraftGroup
) -> List<HDecl> {
    for value in prepared.staged {
        rebind_fn_scheme_with_alias(ctx, value.name, value.scheme)
    }
    publish_owner_batches(ctx, prepared.batches)
    prepared.declarations
}

fn preflight_value_draft_group(
    ctx: InferCtx, prepared: PreparedFnDraftGroup
) {
    for value in prepared.staged {
        let current = ctx.env.lookup(value.name).unwrap_or_else(fn() {
            panic("function group preflight: canonical binding is absent")
        })
        if current.def_id != value.scheme.def_id {
            panic("function group preflight: canonical DefId changed")
        }
        let current_executable = named_executable_for_def_id(
            ctx, current.def_id, "function group preflight")
        if !executable_ref_same(
                current_executable, value.executable) {
            panic("function group preflight: canonical executable changed")
        }

        // Commit updates every lexical alias whose exact DefId maps to this
        // canonical binding. Verify those same entries before any rebind.
        for scope in ctx.env.scope.scopes {
            let mut aliases = scope.variables.entries()
            aliases.sort_by(compare_by_first)
            for entry in aliases {
                let (alias_name, alias_scheme) = entry
                match alias_scheme.def_id {
                    some(alias_id) => match ctx.use_aliases.get(alias_id) {
                        some(origin) => if origin == value.name {
                            match scope.variables.get(alias_name) {
                                some(current_alias) => if
                                        current_alias.def_id != some(alias_id) {
                                    panic(
                                        "function group preflight: alias DefId changed")
                                },
                                none => panic(
                                    "function group preflight: alias target is absent")
                            }
                        },
                        none => {}
                    },
                    none => {}
                }
            }
        }
    }
}

fn preflight_impl_draft_group(
    mut ctx: InferCtx, target_type: Str,
    owner_ref: ImplOwnerRef, prepared: PreparedFnDraftGroup
) {
    let owner = find_impl_by_provider(
        ctx.env.trait_reg, target_type,
        impl_owner_ref_trait(owner_ref),
        impl_owner_ref_provider(owner_ref)).unwrap_or_else(fn() {
        panic("impl group preflight: exact owner is absent")
    })
    match owner.owner_ref {
        some(current_owner) => if !impl_owner_ref_same(
                current_owner, owner_ref) {
            panic("impl group preflight: exact owner changed")
        },
        none => panic("impl group preflight: owner identity is absent")
    }

    let mut seen_names: Set<Str> = set_new()
    let mut invalid = false
    for value in prepared.staged {
        if seen_names.contains(value.name) {
            panic("impl group preflight: method repeats")
        }
        seen_names.insert(value.name)
        if !owner.method_schemes.contains_key(value.name) {
            panic("impl group preflight: method core is absent")
        }
        let incoming = owner.method_refs.get(
            value.name).unwrap_or_else(fn() {
            panic("impl group preflight: method identity is absent")
        })
        if !impl_owner_ref_same(
                impl_method_ref_owner(incoming), owner_ref) {
            panic("impl group preflight: method owner changed")
        }
        if !executable_ref_same(
                make_named_executable_ref(
                    impl_method_ref_member(incoming)),
                value.executable) {
            panic("impl group preflight: method executable changed")
        }
        match ctx.env.trait_reg.method_index.get(target_type) {
            some(methods) => match methods.get(value.name) {
                some(existing) => if !impl_method_ref_same(
                        existing, incoming) {
                    let old_owner = match impl_owner_ref_trait(
                            impl_method_ref_owner(existing)) {
                        some(trait_ref) => "trait '${nominal_display_name(
                            symbol_ref_canonical_payload(trait_ref))}'",
                        none => "an inherent impl"
                    }
                    let new_owner = match owner.trait_name {
                        some(name) => "trait '${nominal_display_name(name)}'",
                        none => "an inherent impl"
                    }
                    let _ = type_error(
                        ctx.sink, E0504,
                        "Ambiguous method '${value.name}' on '${nominal_display_name(target_type)}': provided by ${old_owner} and ${new_owner}",
                        value.span,
                        DiagnosticContext::TraitError {
                            detail: "same-target method origins must be unique"
                        })
                    invalid = true
                },
                none => {}
            },
            none => {}
        }
    }
    if invalid { fail.raise(CompileError {}) }
}

fn validate_impl_draft_group(
    mut ctx: InferCtx, trait_name: Str?, declarations: List<HDecl>
) {
    match trait_name {
        some(name) => if name == "Drop" {
            for declaration in declarations {
                match declaration {
                    HDecl::Fn { name: method_name, effects, span, .. } => {
                        if method_name == "drop" {
                            for eff in effects.effects {
                                match eff {
                                    Effect::FailEffect { .. } => {
                                        let _ = type_error(
                                            ctx.sink, E0803,
                                            "Drop::drop must not have fail effect",
                                            span,
                                            DiagnosticContext::TraitError {
                                                detail: "drop must not fail"
                                            })
                                    },
                                    _ => {}
                                }
                            }
                        }
                    },
                    _ => {}
                }
            }
        },
        none => {}
    }
}

fn commit_impl_draft_group(
    mut ctx: InferCtx, target_type: Str,
    owner_ref: ImplOwnerRef, prepared: PreparedFnDraftGroup
) -> List<HDecl> {
    for value in prepared.staged {
        store_rebound_impl_method_scheme(
            ctx, target_type, owner_ref,
            value.name, value.scheme, value.span)
    }
    publish_owner_batches(ctx, prepared.batches)
    for declaration in prepared.declarations {
        match declaration {
            HDecl::Fn { name, .. } => {
                match ctx.fn_mut_params.get(name) {
                    some(flags) => journal_fn_mut_params_set(
                        ctx, "${target_type}_${name}", flags),
                    none => {}
                }
            },
            _ => {}
        }
    }
    prepared.declarations
}

fn finalize_singleton_fn_draft(
    mut ctx: InferCtx, draft: FnDraft,
    diagnostic_checkpoint: Int
) -> HDecl {
    if draft.impl_method_ref.is_some() {
        panic("function singleton: impl method requires exact owner commit")
    }
    let prepared = prepare_fn_draft_group(
        ctx, [draft], [draft.executable], diagnostic_checkpoint)
    preflight_value_draft_group(ctx, prepared)
    commit_value_draft_group(ctx, prepared).get(0).unwrap()
}

fn infer_and_commit_impl_draft_group(
    mut ctx: InferCtx, target_type: Str, trait_name: Str?,
    impl_owner: ImplEntry, impl_self_type: Type,
    group: List<Str>, impl_fn_map: Map<Str, Decl>, recursive: Bool,
    validation: FnValidationContext
) -> List<HDecl> {
    let mut names = group.map(fn(name) { name })
    names.sort()
    let mut executables: List<ExecutableRef> = []
    for name in names {
        let method_ref = impl_owner.method_refs.get(name).unwrap_or_else(fn() {
            panic("impl method group: exact member is absent")
        })
        executables.push(make_named_executable_ref(
            impl_method_ref_member(method_ref)))
    }

    let saved_subst = ctx.subst
    let diagnostic_checkpoint = ctx.sink.save()
    let mutation_checkpoint = begin_infer_mutation_journal(ctx)
    ctx.subst = empty_subst()
    if recursive {
        begin_recursive_callable_group(ctx, executables)
    }
    let result = some({
        let mut drafts: List<FnDraft> = []
        for name in names {
            drafts.push(infer_impl_method_draft(
                ctx, target_type, impl_owner, impl_self_type,
                impl_fn_map.get(name).unwrap(), validation))
        }
        if diagnostics_since_has_errors(ctx, diagnostic_checkpoint) {
            fail.raise(CompileError {})
        }
        let prepared = prepare_fn_draft_group(
            ctx, drafts, executables, diagnostic_checkpoint)
        validate_impl_draft_group(
            ctx, trait_name, prepared.declarations)
        if diagnostics_since_has_errors(ctx, diagnostic_checkpoint) {
            fail.raise(CompileError {})
        }
        preflight_impl_draft_group(
            ctx, target_type, impl_owner.owner_ref.unwrap(), prepared)
        prepared
    }) catch { _ => none }

    match result {
        some(prepared) => {
            if recursive {
                end_recursive_callable_group(ctx, executables)
            }
            let declarations = commit_impl_draft_group(
                ctx, target_type,
                impl_owner.owner_ref.unwrap(), prepared)
            commit_infer_mutation_journal(ctx, mutation_checkpoint)
            if recursive {
                mark_recursive_callable_group_closed(ctx, executables)
            }
            ctx.subst = saved_subst
            declarations
        },
        none => {
            if recursive {
                end_recursive_callable_group(ctx, executables)
            }
            rollback_infer_mutation_journal(ctx, mutation_checkpoint)
            ctx.subst = saved_subst
            fail.raise(CompileError {})
        }
    }
}
fn check_impl_decl(
    mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>,
    trait_name: Str?, methods: List<Decl>, span: Span, decl_index: Int,
    validation: FnValidationContext
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
        selected_owner, validation)
}

fn check_impl_decl_canonical(
    mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>,
    trait_name: Str?, methods: List<Decl>, span: Span,
    selected_owner: ImplOwnerRef, validation: FnValidationContext
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
    record_nominal_core_parameters(
        ctx, impl_owner_ref_target(selected_owner),
        type_params, impl_owner.type_param_vars)
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
    let exact_target_symbol = match impl_target_symbol(ctx.env, target_type) {
        some(value) => value,
        none => panic("impl HIR: resolved target symbol is absent")
    }
    if !symbol_ref_same(
            impl_owner_ref_target(selected_owner), exact_target_symbol) {
        panic("impl HIR: target type/owner identity differs")
    }
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
                let exact_assoc = match (impl_owner.trait_name,
                        impl_owner.trait_ref) {
                    (some(exact_trait_name), some(exact_trait_ref)) => match
                            ctx.env.trait_reg.traits.get(exact_trait_name) {
                        some(def) => {
                            if !symbol_ref_same(
                                    registered_trait_ref_symbol(def.owner_ref),
                                    exact_trait_ref) {
                                panic("impl HIR: associated-type trait identity drifted")
                            }
                            def.assoc_types.find(fn(item) {
                                item.name == aname
                            })
                        },
                        none => none
                    },
                    _ => none
                }
                match exact_assoc {
                    some(assoc) => hassoc_types.push(HAssocType {
                        name: aname, member_ref: assoc.member_ref,
                        bounds: bound_names, concrete: concrete }),
                    // Registration already diagnosed an associated type that
                    // is absent from the selected trait.  Keep error recovery
                    // local; successful HIR can never take this branch.
                    none => {}
                }
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

    let mut impl_owner_invalid = false
    match trait_name {
        some(name) => {
            let conflicts = if name == "Drop" {
                has_impl(ctx.env.trait_reg, target_type, "Clone")
            } else if name == "Clone" {
                has_impl(ctx.env.trait_reg, target_type, "Drop") ||
                    ctx.drop_types.contains(target_type)
            } else { false }
            if conflicts {
                impl_owner_invalid = true
                let target_display = nominal_display_name(target_type)
                let _ = type_error(ctx.sink, E0802,
                    "type '${target_display}' cannot implement both Drop and Clone",
                    span, DiagnosticContext::TraitError {
                        detail: "Drop and Clone are mutually exclusive"
                    })
            }
        },
        none => {}
    }
    if impl_owner_invalid { fail.raise(CompileError {}) }

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
                    // Retain self recursion so singleton SCCs enter the same
                    // monomorphic group lifecycle as mutual recursion.
                    sorted_callees.push(c)
                }
                sorted_callees.sort()
                impl_call_graph.insert(name, sorted_callees)
            },
            _ => {}
        }
    }

    // Step 3: Run Tarjan SCC to get reverse topo order (callees first)
    let sccs = tarjan_scc(impl_call_graph)

    let mut hmethods: List<HDecl> = []
    for scc in sccs {
        let declarations = infer_and_commit_impl_draft_group(
            ctx, target_type, trait_name, impl_owner, impl_self_type,
            scc, impl_fn_map,
            scc_group_is_recursive(scc, impl_call_graph), validation)
        for declaration in declarations { hmethods.push(declaration) }
    }

    let mut default_specializations: List<HDefaultSpecializationPlan> = []
    match trait_name {
        some(exact_trait_name) => {
            let trait_def = ctx.env.trait_reg.traits.get(
                exact_trait_name).unwrap_or_else(fn() {
                panic("default specialization: trait contract is absent")
            })
            for trait_method in trait_def.methods {
                if trait_method.has_default &&
                   !impl_owner.method_names.contains(trait_method.name) {
                    let generated_method = impl_owner.method_refs.get(
                        trait_method.name).unwrap_or_else(fn() {
                        panic("default specialization: generated method ref is absent")
                    })
                    let core = impl_owner.method_schemes.get(
                        trait_method.name).unwrap_or_else(fn() {
                        panic("default specialization: specialized scheme is absent")
                    })
                    let signature = impl_method_core_type(core)
                    let (parameter_types, result_type, effects) = match signature {
                        Type::FnType { params, return_type, effects } =>
                            (params, return_type, effects),
                        _ => panic(
                            "default specialization: scheme is not callable")
                    }
                    let generated_executable = make_named_executable_ref(
                        impl_method_ref_member(generated_method))
                    let default_executable = make_named_executable_ref(
                        trait_method_ref_member(trait_method.method_ref))
                    let mut binders: List<BinderEntry> = []
                    for index in 0..parameter_types.len() {
                        binders.push(semantic_parameter_binder(
                            ctx, generated_executable,
                            ctx.env.fresh_def_id(), index,
                            "default-specialization"))
                    }
                    enter_executable_owner(ctx, generated_executable)
                    let generated_effect_ctx = current_typed_callable_effect_ctx(
                        ctx, effects, impl_method_core_effect_schema(core))
                    let forward_effect_ctx = effect_ctx_source_for_callable(
                        ctx, signature)
                    exit_executable_owner(ctx)
                    let definition_receipt =
                        make_callable_impl_definition_receipt(
                            impl_owner, core, generated_method)
                    let dict_evidence = resolve_immediate_impl_owner_dicts(
                        generated_executable,
                        ctx.sink, ctx.env, impl_bounds,
                        impl_owner, core, definition_receipt,
                        ctx.subst, span)
                    let d1_checkpoint = ctx.sink.save()
                    check_final_runtime_handled_contract(
                        ctx, signature, some(generated_effect_ctx),
                        trait_method.name, span)
                    if diagnostics_since_has_errors(ctx, d1_checkpoint) {
                        fail.raise(CompileError {})
                    }
                    publish_exact_callable_effect_header(
                        ctx, generated_executable, signature,
                        impl_method_core_effect_schema(core))
                    default_specializations.push(
                        make_h_default_specialization_plan(
                            selected_owner, generated_method,
                            generated_executable, trait_method.method_ref,
                            default_executable, parameter_types,
                            trait_method.param_mutabilities, binders,
                            result_type, effects, generated_effect_ctx,
                            make_h_exact_call_plan(
                                make_named_callee_ref(
                                    trait_method_ref_member(
                                        trait_method.method_ref)),
                                signature, none,
                                dict_evidence, forward_effect_ctx)))
                }
            }
        },
        none => {}
    }

    match trait_name {
        some(name) => if name == "Drop" {
            ctx.drop_types.insert(target_type)
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
        target_ty: impl_self_type,
        owner_ref: owner_ref,
        provider_ref: provider_ref, trait_ref: impl_owner.trait_ref,
        delegate_plan: none,
        default_specializations: default_specializations,
        type_params: exact_h_type_params(
            ctx, type_params, impl_owner.type_param_vars),
        trait_name: trait_name,
        methods: hmethods, assoc_types: hassoc_types, span: span
    }
}

fn expand_delegate_impls(
    mut ctx: InferCtx, outer_impl: HDecl, source_member_index: Int,
    field: Str, span: Span, validation: FnValidationContext
) -> List<HDecl> {
    let mut result: List<HDecl> = []
    let (target_type, target_ty, type_params,
         outer_provider_ref, outer_trait_ref) =
        match outer_impl {
            HDecl::Impl {
                target_type, target_ty, type_params,
                provider_ref, trait_ref, ..
            } => (target_type, target_ty, type_params,
                  provider_ref, trait_ref),
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
                            match ctx.type_param_scope.get(
                                    h_type_param_source(tp).name) {
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
                                            let trait_def = ctx.env.trait_reg.traits.get(
                                                bound.trait_name).unwrap_or_else(fn() {
                                                panic("delegate HIR: generated bound trait is absent")
                                            })
                                            generated_trait_bounds.push(TraitBound {
                                                type_param: bound.type_param_name,
                                                type_var_id:
                                                    bound.type_param_var_id,
                                                trait_name: bound.trait_name,
                                                trait_ref: registered_trait_ref_symbol(
                                                    trait_def.owner_ref),
                                                dict_ordinal: bound.dict_ordinal
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
                                            let assoc_schema = match
                                                    field_entry.assoc_type_effect_schemas.get(
                                                        assoc_name) {
                                                some(schema) => schema,
                                                none => panic(
                                                    "delegate HIR: assoc effect schema is absent")
                                            }
                                            let localized =
                                                instantiate_effect_header_schema(
                                                    ctx.env, [assoc_type],
                                                    assoc_schema)
                                            field_assoc_map.insert(
                                                assoc_name,
                                                apply_subst_map(
                                                    field_var_map,
                                                    localized.0.get(0).unwrap()))
                                        }
                                    },
                                    none => {}
                                }

                                let mut trait_hmethods: List<HDecl> = []
                                let mut delegate_method_plans: List<HDelegateMethodPlan> = []
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
                                    let mut generated_method_type_var_ids: List<Int> = []
                                    match resolved_method_scheme {
                                        some(scheme) => {
                                            if scheme.type_vars.len() <
                                               tm.method_type_params.len() {
                                                panic(
                                                    "delegate HIR: method type parameter arity differs")
                                            }
                                            let start = scheme.type_vars.len() -
                                                tm.method_type_params.len()
                                            for index in start..scheme.type_vars.len() {
                                                generated_method_type_var_ids.push(
                                                    scheme.type_vars.get(index).unwrap())
                                            }
                                        },
                                        none => if tm.method_type_params.len() != 0 {
                                            panic(
                                                "delegate HIR: generic method scheme is absent")
                                        }
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
                                                        source_slot: some(make_source_slot_ref(
                                                            current_identity_file_key(ctx),
                                                            slot_domain_lexical(), pid)),
                                                        callee_identity: match param_ty {
                                                            Type::FnType { .. } => some(make_local_callee_ref(
                                                                make_source_slot_ref(
                                                                    current_identity_file_key(ctx),
                                                                    slot_domain_lexical(), pid))),
                                                            _ => none
                                                        },
                                                        dict_closure_dicts: none,
                                                        callable_instantiation: none,
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
                                                        projection: some(h_nominal_projection(
                                                            exact_field_ref)),
                                                        ty: resolved_ft,
                                                        effects: EMPTY_ROW,
                                                        span: span
                                                    })
                                                } else {
                                                    forward_args.push(HExpr::Ident {
                                                        name: pname, resolved_name: none, def_id: some(pid),
                                                        source_slot: some(make_source_slot_ref(
                                                            current_identity_file_key(ctx),
                                                            slot_domain_lexical(), pid)),
                                                        callee_identity: match resolved_pty {
                                                            Type::FnType { .. } => some(make_local_callee_ref(
                                                                make_source_slot_ref(
                                                                    current_identity_file_key(ctx),
                                                                    slot_domain_lexical(), pid))),
                                                            _ => none
                                                        },
                                                        dict_closure_dicts: none,
                                                        callable_instantiation: none,
                                                        ty: resolved_pty, effects: EMPTY_ROW, span: span
                                                    })
                                                }
                                                pi = pi + 1
                                            }

                                            // Build: self.field
                                            let field_access = HExpr::FieldAccess {
                                                receiver: HExpr::Ident {
                                                    name: "self", resolved_name: none, def_id: some(def_id_self),
                                                    source_slot: some(make_source_slot_ref(
                                                        current_identity_file_key(ctx),
                                                        slot_domain_lexical(), def_id_self)),
                                                    callee_identity: none,
                                                    dict_closure_dicts: none,
                                                    callable_instantiation: none,
                                                    ty: exact_self_type, effects: EMPTY_ROW, span: span
                                                },
                                                projection: some(h_nominal_projection(
                                                    exact_field_ref)),
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
                                            // on the field type. If so, use exact bound evidence instead of UFCS.
                                            let mut use_bound_evidence = false
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
                                                            use_bound_evidence = true
                                                        }
                                                    },
                                                    none => {}
                                                }
                                            }

                                            let field_callee_type = match field_method_scheme {
                                                some((_field_core, field_scheme)) =>
                                                    apply_subst_map(
                                                        field_var_map,
                                                        field_scheme.ty),
                                                none => apply_subst_map(
                                                    field_var_map, tm.ty)
                                            }
                                            match field_callee_type {
                                                Type::FnType {
                                                    params: exact_params,
                                                    return_type: exact_result, ..
                                                } => {
                                                    if exact_params.len() == 0 ||
                                                       !types_equal(
                                                            exact_params.get(0).unwrap(),
                                                            resolved_ft) ||
                                                       !types_equal(exact_result, ret_ty) {
                                                        panic(
                                                            "delegate HIR: field callee specialization differs")
                                                    }
                                                },
                                                _ => panic(
                                                    "delegate HIR: field callee is not callable")
                                            }

                                            let generated_method_ref = match delegate_impl {
                                                some(wrapper) => match
                                                        wrapper.method_refs.get(tm.name) {
                                                    some(reference) => reference,
                                                    none => panic(
                                                        "delegate HIR: wrapper lost exact method")
                                                },
                                                none => panic(
                                                    "delegate HIR: wrapper owner is missing")
                                            }
                                            let generated_executable =
                                                make_named_executable_ref(
                                                    impl_method_ref_member(
                                                        generated_method_ref))

                                            let call_expr = if use_bound_evidence {
                                                // Generate exact bound dispatch through __FieldType_Trait evidence.
                                                let ftn = match resolved_ft {
                                                    Type::StructType { name: n, .. } => n,
                                                    Type::EnumType { name: n, .. } => n,
                                                    _ => ""
                                                }
                                                let dict_name = trait_dict_name(ftn, tname)
                                                let bound_owner = match field_impl {
                                                    some(value) => match value.owner_ref {
                                                        some(owner) => owner,
                                                        none => panic(
                                                            "delegate HIR: field impl owner is absent")
                                                    },
                                                    none => panic(
                                                        "delegate HIR: bound method impl is absent")
                                                }
                                                let exact_bound_ref =
                                                    make_bound_method_call_ref(
                                                        tm.method_ref,
                                                        make_static_dict_ref(
                                                            dict_name,
                                                            make_exact_static_dict_ref(
                                                                bound_owner)),
                                                        field_callee_type,
                                                        tm.param_mutabilities.first().unwrap_or(false))
                                                HExpr::Call {
                                                    callee: HExpr::FieldAccess {
                                                        receiver: field_access,
                                                        field: tm.name,
                                                        access_kind: HFieldAccessKind::Method,
                                                        projection: none,
                                                        ty: field_callee_type,
                                                        effects: EMPTY_ROW,
                                                        span: span
                                                    },
                                                    args: forward_args,
                                                    type_args: [],
                                                    effect_instantiation: none,
                                                    resolved_dicts: [],
                                                    effect_ctx:
                                                        make_empty_effect_ctx_source(),
                                                    callee_ref: none,
                                                    method_ref: some(exact_bound_ref),
                                                    system_host: none,
                                                    ty: ret_ty,
                                                    effects: eff,
                                                    span: span
                                                }
                                            } else {
                                                let resolved_forward_dicts = match delegate_impl {
                                                    some(generated_owner) => {
                                                        let generated_core =
                                                            generated_owner.method_schemes.get(
                                                                tm.name).unwrap_or_else(fn() {
                                                                    panic(
                                                                        "delegate HIR: generated method core is absent")
                                                                })
                                                        let definition_receipt =
                                                            make_callable_impl_definition_receipt(
                                                                generated_owner,
                                                                generated_core,
                                                                generated_method_ref)
                                                        resolve_immediate_impl_owner_dicts(
                                                            generated_executable,
                                                            ctx.sink, ctx.env,
                                                            generated_fn_bounds,
                                                            generated_owner,
                                                            generated_core,
                                                            definition_receipt,
                                                            ctx.subst, span)
                                                    },
                                                    none => []
                                                }
                                                // Build: self.field.method — as FieldAccess for UFCS dispatch
                                                let method_access = HExpr::FieldAccess {
                                                    receiver: field_access,
                                                    field: tm.name,
                                                    access_kind: HFieldAccessKind::Method,
                                                    projection: none,
                                                    ty: field_callee_type,
                                                    effects: EMPTY_ROW,
                                                    span: span
                                                }

                                                // Build: self.field.method(args...) — as Call with UFCS callee
                                                let exact_forward_ref = match field_impl {
                                                    some(field_owner) => match
                                                            field_owner.method_intrinsics.get(tm.name) {
                                                        some(intrinsic) =>
                                                            make_intrinsic_method_call_ref(
                                                                intrinsic,
                                                                field_callee_type),
                                                        none => match
                                                                field_owner.method_refs.get(tm.name) {
                                                            some(method_ref) =>
                                                                make_concrete_method_call_ref(
                                                                    method_ref,
                                                                    field_callee_type,
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
                                                    effect_instantiation: none,
                                                    resolved_dicts: resolved_forward_dicts,
                                                    effect_ctx:
                                                        make_empty_effect_ctx_source(),
                                                    callee_ref: none,
                                                    method_ref: some(exact_forward_ref),
                                                    system_host: none,
                                                    ty: ret_ty,
                                                    effects: eff,
                                                    span: span
                                                }
                                            }

                                            let generated_schema = match
                                                    resolved_method_scheme {
                                                some(scheme) =>
                                                    scheme.effect_schema,
                                                none => panic(
                                                    "delegate HIR: generated effect schema is absent")
                                            }
                                            enter_executable_owner(
                                                ctx, generated_executable)
                                            let generated_effect_ctx =
                                                current_typed_callable_effect_ctx(
                                                    ctx, eff, generated_schema)
                                            let child_effect_ctx =
                                                effect_ctx_source_for_callable(
                                                    ctx, field_callee_type)
                                            exit_executable_owner(ctx)
                                            let call_expr =
                                                with_call_effect_ctx(
                                                    call_expr, child_effect_ctx)
                                            let (child_call, child_evidence) =
                                                match call_expr {
                                                    HExpr::Call {
                                                        method_ref: some(method),
                                                        resolved_dicts, ..
                                                    } => (method, resolved_dicts),
                                                    _ => panic(
                                                        "delegate HIR: generated body is not one exact method call")
                                                }
                                            let mut method_binders: List<BinderEntry> = []
                                            let mut parameter_types: List<Type> = []
                                            let mut binder_index = 0
                                            for parameter in hparams {
                                                let parameter_def_id = match parameter.def_id {
                                                    some(id) => id,
                                                    none => panic(
                                                        "delegate HIR: generated parameter has no DefId")
                                                }
                                                method_binders.push(
                                                    semantic_parameter_binder(
                                                        ctx, generated_executable,
                                                        parameter_def_id,
                                                        binder_index,
                                                        "delegate"))
                                                parameter_types.push(parameter.ty)
                                                binder_index = binder_index + 1
                                            }
                                            let validation_checkpoint =
                                                ctx.sink.save()
                                            let generated_signature = Type::FnType {
                                                params: parameter_types,
                                                return_type: ret_ty,
                                                effects: eff
                                            }
                                            check_final_runtime_handled_contract(
                                                ctx, generated_signature,
                                                some(generated_effect_ctx),
                                                tm.name, span)
                                            if !typed_callable_header_has_closed_handled_instances(
                                                    field_callee_type) {
                                                report_open_runtime_handled_instance(
                                                    ctx, "delegate call", span)
                                            }
                                            match (validation.capability,
                                                   validation.capability_span) {
                                                (some(capability), some(cap_span)) =>
                                                    check_effects_capability(
                                                        ctx, tm.name, eff,
                                                        capability, cap_span),
                                                (none, none) => {},
                                                _ => panic(
                                                    "delegate validation: capability context is incomplete")
                                            }
                                            if diagnostics_since_has_errors(
                                                    ctx, validation_checkpoint) {
                                                fail.raise(CompileError {})
                                            }
                                            publish_exact_callable_effect_header(
                                                ctx, generated_executable,
                                                generated_signature,
                                                generated_schema)
                                            delegate_method_plans.push(
                                                make_h_delegate_method_plan(
                                                    tm.method_ref,
                                                    generated_method_ref,
                                                    generated_executable,
                                                    make_symbol_origin_ref(
                                                        impl_method_ref_member(
                                                            generated_method_ref)),
                                                    child_call,
                                                    method_call_ref_callee_identity(
                                                        child_call),
                                                    method_binders,
                                                    parameter_types,
                                                    ret_ty, eff,
                                                    child_evidence,
                                                    generated_effect_ctx,
                                                    child_effect_ctx))
                                            trait_hmethods.push(HDecl::Fn {
                                                name: tm.name,
                                                def_id: some(ctx.env.fresh_def_id()),
                                                executable_ref: generated_executable,
                                                impl_method_ref:
                                                    some(generated_method_ref),
                                                // #77: Copy method type_params from trait method declaration
                                                type_params: exact_h_type_params(
                                                    ctx, tm.method_type_params,
                                                    generated_method_type_var_ids),
                                                params: hparams,
                                                return_type: ret_ty,
                                                effects: eff,
                                                effect_ctx: generated_effect_ctx,
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
                                    let assoc = trait_def.assoc_types.find(
                                        fn(item) { item.name == aname }
                                    ).unwrap_or_else(fn() {
                                        panic("delegate HIR: associated member identity is absent")
                                    })
                                    h_assoc_types.push(HAssocType {
                                        name: aname, member_ref: assoc.member_ref,
                                        bounds: [], concrete: some(aty) })
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
                                let outer_owner_ref = match outer_owner.owner_ref {
                                    some(owner) => owner,
                                    none => panic(
                                        "delegate HIR: outer owner has no typed identity")
                                }
                                let exact_field_owner = match field_impl {
                                    some(owner) => owner,
                                    none => panic(
                                        "delegate HIR: field impl owner is missing")
                                }
                                let field_owner_ref = match exact_field_owner.owner_ref {
                                    some(owner) => owner,
                                    none => panic(
                                        "delegate HIR: field owner has no typed identity")
                                }
                                let field_provider_ref = match
                                        exact_field_owner.provider_ref {
                                    some(provider) => provider,
                                    none => panic(
                                        "delegate HIR: field owner has no provider")
                                }
                                let mut delegate_assoc_plans: List<HDelegateAssocPlan> = []
                                for assoc in trait_def.assoc_types {
                                    match field_assoc_map.get(assoc.name) {
                                        some(ty) => delegate_assoc_plans.push(
                                            make_h_delegate_assoc_plan(
                                                assoc.member_ref, ty)),
                                        none => {}
                                    }
                                }
                                let delegate_typed_plan = make_h_delegate_typed_plan(
                                    trait_def.contract,
                                    outer_owner_ref, selected_delegate_ref,
                                    selected_delegate_provider,
                                    field_owner_ref, field_provider_ref,
                                    impl_owner_ref_target(field_owner_ref),
                                    exact_field_ref, produced_trait_ref,
                                    source_member_index,
                                    delegate_method_plans,
                                    delegate_assoc_plans, [])
                                result.push(HDecl::Impl {
                                    target_type: target_type,
                                    target_ty: target_ty,
                                    owner_ref: selected_delegate_ref,
                                    provider_ref: selected_delegate_provider,
                                    trait_ref: selected_delegate_owner.trait_ref,
                                    delegate_plan: some(delegate_typed_plan),
                                    default_specializations: [],
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
    record_nominal_core_parameters(
        ctx, registered_trait_ref_symbol(trait_def.owner_ref),
        type_params, trait_def.type_param_vars)

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
        let mut method_body_effect_ctx: TypedCallableEffectCtx? = none
        if m.has_default {
            match ast_method {
                Decl::Fn { body: abody, span: method_span, .. } => {
                    let has_body = match abody {
                        Expr::Block { stmts, tail, .. } => stmts.len() > 0 || tail.is_some(),
                        _ => true
                    }
                    if has_body {
                        let method_identity = "${name}::${m.name}"
                        let checked_default = check_trait_default_body(
                            ctx, name, method_identity,
                            make_named_executable_ref(
                                trait_method_ref_member(m.method_ref)),
                            self_var, hparams, fn_ret, fn_effects,
                            m.effect_schema, method_span, abody)
                        method_body = checked_default.body
                        method_body_effect_ctx = some(
                            checked_default.effect_ctx)
                    }
                },
                _ => panic("trait HIR: exact default method changed kind")
            }
        }

        let method_executable = make_named_executable_ref(
            trait_method_ref_member(m.method_ref))
        let effect_ctx = match method_body_effect_ctx {
            some(values) => values,
            none => {
                enter_executable_owner(ctx, method_executable)
                let values = current_typed_callable_effect_ctx(
                    ctx, fn_effects, m.effect_schema)
                exit_executable_owner(ctx)
                values
            }
        }
        hmethods.push(HTraitMethod {
            name: m.name, method_ref: m.method_ref,
            params: hparams, return_type: fn_ret,
            effects: fn_effects, has_default: m.has_default,
            executable_ref: method_executable,
            effect_ctx: effect_ctx,
            body: method_body
        })
    }

    // Build HAssocType list from trait def
    let mut hassoc_types: List<HAssocType> = []
    for atdef in trait_def.assoc_types {
        hassoc_types.push(HAssocType {
            name: atdef.name, member_ref: atdef.member_ref,
            bounds: atdef.bounds, concrete: atdef.default_type })
    }

    HDecl::Trait {
        name: name, owner_ref: trait_def.owner_ref,
        type_params: exact_h_type_params(
            ctx, type_params, trait_def.type_param_vars), methods: hmethods,
        supertraits: trait_def.supertraits,
        assoc_types: hassoc_types, is_pub: is_pub, span: span
    }
}

struct TraitDefaultBodyResult {
    body: HExpr?,
    effect_ctx: TypedCallableEffectCtx
}

fn check_trait_default_body(
    mut ctx: InferCtx, trait_name: Str, method_identity: Str,
    executable_ref: ExecutableRef,
    self_var: Type, hparams: List<HParam>, method_return: Type,
    method_effects: EffectRow, method_schema: TypedEffectHeaderSchema,
    method_span: Span, body: Expr
) -> TraitDefaultBodyResult {
    let batch_checkpoint = owner_batch_checkpoint(ctx)
    enter_executable_owner(ctx, executable_ref)
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
                type_param_name: "self",
                dict_ordinal: ctx.current_fn_bounds.len(),
                assoc_constraints: []
            })
            // Expand supertrait bounds for trait default body
            let supers = collect_all_supertraits(ctx, trait_name)
            for st_name in supers {
                ctx.current_fn_bounds.push(FnBoundsEntry {
                    type_param_var_id: id, trait_name: st_name,
                    type_param_name: "self",
                    dict_ordinal: ctx.current_fn_bounds.len(),
                    assoc_constraints: []
                })
            }
        },
        _ => {}
    }
    validate_fn_bound_order(ctx.current_fn_bounds)

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
            effect_schema: empty_typed_effect_header_schema(),
            def_id: some(exact_trait_def_id)
        })
        if p.is_mutable {
            match ctx.env.lookup(p.name) {
                some(ps) => match ps.def_id {
                    some(did) => journal_mutable_var_insert(ctx, did),
                    none => {}
                },
                none => {}
            }
        }
    }

    let body_result = some(infer_block(ctx, body, none)) catch { _ => none }
    let mut detached_batch: OwnerInferenceBatch? = none

    let final_body_unremapped = match body_result {
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
            let batch = detach_owner_batch(ctx, batch_checkpoint)
            match some(drain_owner_batch_dictionaries(
                    ctx, batch, ctx.subst)) catch { _ => none } {
                some(value) => {
                    detached_batch = some(value)
                    let zctx = ZonkCtx {
                        subst: ctx.subst, names: map_new(),
                        canonical_type_var_ids: map_new(),
                        dict_resolver: none
                    }
                    some(zonk_block(zctx, br.hexpr))
                },
                none => {
                    rollback_owner_batch(ctx, batch_checkpoint)
                    ctx.subst = saved_subst
                    none
                }
            }
        },
        none => {
            rollback_owner_batch(ctx, batch_checkpoint)
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
    let final_batch_unstaged = match detached_batch {
        some(value) => value,
        none => {
            exit_executable_owner(ctx)
            ctx.subst = saved_subst
            fail.raise(CompileError {})
        }
    }
    let frozen_subst = ctx.subst
    let callable_signature = Type::FnType {
        params: hparams.map(fn(param) { param.ty }),
        return_type: method_return, effects: method_effects
    }
    let final_batch = stage_owner_batch_facts(
        ctx, final_batch_unstaged, executable_ref,
        callable_signature, method_schema, frozen_subst, map_new())
    let d1_checkpoint = ctx.sink.save()
    let effect_ctx = current_typed_callable_effect_ctx_from_owner_batch(
        ctx, final_batch, method_effects)
    let final_body = final_body_unremapped.map(fn(value) {
        finalize_effect_ctx_expr(
            ctx, FinalEffectCtxAuthority::FinalEffectCtxOwnerBatch(final_batch),
            value)
    })
    check_final_runtime_handled_contract(
        ctx, callable_signature, some(effect_ctx),
        method_identity, method_span)
    if diagnostics_since_has_errors(ctx, d1_checkpoint) {
        rollback_owner_batch(ctx, batch_checkpoint)
        ctx.subst = saved_subst
        exit_executable_owner(ctx)
        fail.raise(CompileError {})
    }
    preflight_owner_batches(ctx, [final_batch])
    publish_owner_batches(ctx, [final_batch])
    ctx.subst = saved_subst
    exit_executable_owner(ctx)
    TraitDefaultBodyResult {
        body: final_body,
        effect_ctx: effect_ctx
    }
}

fn conservative_extern_resource_contract(
    params: List<HParam>, result: Type
) -> CallableResourceContractFact {
    let mut roles: List<CallableResourceRoleFact> = []
    for param in params {
        roles.push(if param.is_mutable {
            callable_resource_role_mutate()
        } else { callable_resource_role_read() })
    }
    let result_owned = match result {
        Type::UnitType | Type::NeverType => false,
        _ => true
    }
    make_callable_resource_contract_fact(
        roles,
        if result_owned { callable_resource_role_consume() }
        else { callable_resource_role_read() }, [])
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
    let abi_name = extern_abi_leaf(name)
    let source_symbol = match scheme.def_id {
        some(id) => value_symbol_ref(ctx, id),
        none => panic("extern HIR: executable DefId is missing")
    }
    let compiler_owned = compiler_owned_extern_manifest_entry(
        ctx.env, source_symbol)
    let resource_contract = match compiler_owned {
        some(entry) => {
            let resource = compiler_extern_manifest_entry_resource(entry)
            if callable_resource_contract_parameter_roles(resource).len() !=
               hparams.len() {
                panic("extern resource contract: manifest arity differs")
            }
            resource
        },
        none => conservative_extern_resource_contract(hparams, fn_ret)
    }
    let _ = declared_effects
    let extern_effects = match scheme.ty {
        Type::FnType { effects, .. } => effects,
        _ => EMPTY_ROW
    }
    let mut system_count = 0
    let mut system_contract_invalid = extern_effects.tail.is_some()
    for atom in extern_effects.effects {
        match atom {
            Effect::SystemEffect { .. } => {
                system_count = system_count + 1
            },
            Effect::FailEffect { .. } => {},
            Effect::CustomEffect { .. } | Effect::MutEffect { .. } |
            Effect::UnsafeEffect => {
                system_contract_invalid = true
            }
        }
    }
    if system_count > 0 &&
       (system_count != 1 || system_contract_invalid) {
        let _ = type_error(ctx.sink, E0407,
            "Host extern '${name}' must declare exactly one system capability and may combine it only with fail",
            span, DiagnosticContext::OtherContext { detail: some(
                "system effects are exact AbiIR host imports, not handled evidence") })
        fail.raise(CompileError {})
    }
    let executable_ref = match compiler_owned {
        some(entry) => compiler_extern_manifest_entry_executable(entry),
        none => make_named_executable_ref(source_symbol)
    }
    let _ = publish_final_value_effect_schema(
        ctx, name, executable_ref, Type::FnType {
            params: hparams.map(fn(param) { param.ty }),
            return_type: fn_ret, effects: extern_effects
        })
    exit_executable_owner(ctx)
    let mut trait_bounds: List<TraitBound> = []
    let extern_type_var_ids = exact_source_type_var_ids(
        scheme, 0, type_params.len())
    let mut type_param_index = 0
    for type_param in type_params {
        for bound in type_param.bounds {
            let trait_name = resolve_trait_identity(
                ctx, bound.trait_name)
            let trait_def = ctx.env.trait_reg.traits.get(
                trait_name).unwrap_or_else(fn() {
                panic("extern HIR: bound trait is absent")
            })
            trait_bounds.push(TraitBound {
                type_param: type_param.name,
                type_var_id: extern_type_var_ids.get(
                    type_param_index).unwrap(),
                trait_name: trait_name,
                trait_ref: registered_trait_ref_symbol(
                    trait_def.owner_ref),
                dict_ordinal: trait_bounds.len() })
        }
        type_param_index = type_param_index + 1
    }
    HDecl::ExternFn {
        name: name, abi_name: abi_name,
        def_id: scheme.def_id,
        executable_ref: executable_ref,
        type_params: exact_h_type_params(
            ctx, type_params, extern_type_var_ids),
        params: hparams, return_type: fn_ret, effects: extern_effects,
        resource_contract: resource_contract,
        trait_bounds: trait_bounds,
        is_pub: is_pub, span: span
    }
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

fn insert_canonical_type_var_id(
    mut values: Map<Int, Int>, representative: Int, canonical: Int
) {
    match values.get(representative) {
        some(existing) => if existing != canonical {
            panic(
                "function zonk: two source type parameters share one representative")
        },
        none => values.insert(representative, canonical)
    }
}

struct FnConstraintResult {
    body: HExpr,
    owner_effects: EffectRow
}

fn infer_fn_body_constraints(
    mut ctx: InferCtx, fn_name: Str, expected_ret: Type,
    declared_effects: EffectRow?, registered_effects: EffectRow?,
    body: Expr, span: Span
) -> FnConstraintResult {
    let body_result = infer_block(ctx, body, some(ctx.subst))
    ctx.subst = body_result.subst
    // Skip body-vs-return unification when the body type is Never (bottom).
    // Never is compatible with any type, but unify(Never, ?T) would bind ?T = Never,
    // contaminating the return type and the final callable scheme.
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
        none => match registered_effects {
            some(provisional_row) => {
                ctx.subst = unify_at(
                    ctx.sink, ctx.env,
                    Type::EffectRowType {
                        effects: body_result.effects.effects,
                        tail: body_result.effects.tail
                    },
                    Type::EffectRowType {
                        effects: provisional_row.effects,
                        tail: provisional_row.tail
                    },
                    ctx.subst, span)
                provisional_row
            },
            none => body_result.effects
        }
    }

    FnConstraintResult {
        body: body_result.hexpr,
        owner_effects: owner_effects
    }
}

fn capture_raw_type_var_names(
    ctx: InferCtx, type_params: List<TypeParam>,
    saved_tp_scope: Map<Str, Type>
) -> Map<Int, Str> {
    let mut result: Map<Int, Str> = map_new()
    let mut declared_names: Set<Str> = set_new()
    for parameter in type_params {
        declared_names.insert(parameter.name)
        match ctx.type_param_scope.get(parameter.name) {
            some(Type::TypeVar { id, .. }) =>
                result.insert(id, parameter.name),
            _ => {}
        }
    }
    let mut entries = ctx.type_param_scope.entries()
    entries.sort_by(compare_by_first)
    for entry in entries {
        let (name, value) = entry
        if !saved_tp_scope.contains_key(name) &&
           !declared_names.contains(name) {
            match value {
                Type::TypeVar { id, .. } => result.insert(id, name),
                _ => {}
            }
        }
    }
    for bound in ctx.current_fn_bounds {
        for constraint in bound.assoc_constraints {
            match constraint.ty {
                Type::TypeVar { id, .. } =>
                    result.insert(id, constraint.name),
                _ => {}
            }
        }
    }
    result
}

fn capture_raw_assoc_rebind_sources(
    ctx: InferCtx, registration_scheme: TypeScheme
) -> List<AssocRebindEntry> {
    let mut result: List<AssocRebindEntry> = []
    for bound in ctx.current_fn_bounds {
        match ctx.env.trait_reg.traits.get(bound.trait_name) {
            some(trait_def) => {
                for assoc in trait_def.assoc_types {
                    let key = "${bound.type_param_name}::${assoc.name}"
                    match ctx.qualified_assoc_scope.get(key) {
                        some(check_type) => {
                            let mut registration_type: Type? = none
                            for scheme_bound in registration_scheme.bounds {
                                if scheme_bound.type_var ==
                                       bound.type_param_var_id &&
                                   scheme_bound.trait_name ==
                                       bound.trait_name {
                                    for constraint in
                                            scheme_bound.assoc_constraints {
                                        if constraint.name == assoc.name {
                                            registration_type =
                                                some(constraint.ty)
                                        }
                                    }
                                }
                            }
                            if registration_type.is_none() &&
                               registration_scheme.bounds.len() == 0 {
                                for constraint in bound.assoc_constraints {
                                    if constraint.name == assoc.name {
                                        registration_type = some(constraint.ty)
                                    }
                                }
                            }
                            result.push(AssocRebindEntry {
                                check_type: check_type,
                                registration_type: registration_type,
                                owner_name: bound.type_param_name,
                                trait_name: bound.trait_name,
                                assoc_name: assoc.name
                            })
                        },
                        none => {}
                    }
                }
            },
            none => {}
        }
    }
    result
}
fn materialize_trait_bounds(
    ctx: InferCtx, values: List<FnBoundsEntry>
) -> List<TraitBound> {
    let mut result: List<TraitBound> = []
    for value in values {
        let trait_def = ctx.env.trait_reg.traits.get(
            value.trait_name).unwrap_or_else(fn() {
            panic("function HIR: bound trait is absent")
        })
        result.push(TraitBound {
            type_param: value.type_param_name,
            trait_name: value.trait_name,
            type_var_id: value.type_param_var_id,
            trait_ref: registered_trait_ref_symbol(trait_def.owner_ref),
            dict_ordinal: value.dict_ordinal
        })
    }
    result
}

fn infer_fn_draft(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    params: List<Param>, return_type: TypeExpr?,
    declared_effects: List<EffectExpr>?, body: Expr,
    is_pub: Bool, span: Span, self_type: Type?,
    registration_override: TypeScheme?, rebind_identity: Str?,
    impl_method_ref: ImplMethodRef?, inherited_type_var_ids: List<Int>,
    validation: FnValidationContext
) -> FnDraft {
    let registration_scheme = match registration_override {
        some(scheme) => scheme,
        none => ctx.env.lookup(name).unwrap_or_else(fn() {
            panic("function draft: registration scheme is absent")
        })
    }
    let executable = match impl_method_ref {
        some(method_ref) => make_named_executable_ref(
            impl_method_ref_member(method_ref)),
        none => named_executable_for_def_id(
            ctx, registration_scheme.def_id, "function '${name}'")
    }
    let provenance_key = match rebind_identity {
        some(identity) => identity,
        none => name
    }
    let batch_checkpoint = owner_batch_checkpoint(ctx)
    enter_executable_owner(ctx, executable)
    let result = some(infer_fn_draft_transaction(
        ctx, name, provenance_key, executable, type_params, params,
        return_type, declared_effects, body, is_pub, span, self_type,
        registration_scheme, impl_method_ref, inherited_type_var_ids,
        validation, batch_checkpoint)) catch { _ => none }
    match result {
        some(draft) => draft,
        none => {
            rollback_owner_batch(ctx, batch_checkpoint)
            fail.raise(CompileError {})
        }
    }
}

fn infer_fn_draft_transaction(
    mut ctx: InferCtx, name: Str, provenance_key: Str,
    executable: ExecutableRef, type_params: List<TypeParam>,
    params: List<Param>, return_type: TypeExpr?,
    declared_effects: List<EffectExpr>?, body: Expr,
    is_pub: Bool, span: Span, self_type: Type?,
    registration_scheme: TypeScheme,
    impl_method_ref: ImplMethodRef?,
    inherited_type_var_ids: List<Int>,
    validation: FnValidationContext,
    batch_checkpoint: OwnerBatchCheckpoint
) -> FnDraft {
    let (registered_params, registered_return, registered_effects) =
        match registration_scheme.ty {
            Type::FnType { params, return_type, effects } =>
                (params, return_type, effects),
            _ => panic("function draft: registration is not callable")
        }
    if registered_params.len() != params.len() {
        panic("function draft: registration parameter census differs")
    }

    let saved_fn_return = ctx.current_fn_return_type
    let saved_tp_scope = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    let saved_fn_bounds = ctx.current_fn_bounds
    let env_scope_depth = ctx.env.scope.scopes.len()
    let fn_bounds_stack_depth = ctx.fn_bounds_stack.len()
    let transaction = some({
    ctx.env.push_scope()
    ctx.fn_bounds_stack.push(ctx.current_fn_bounds)
    let mut inherited_bounds: List<FnBoundsEntry> = []
    for bound in ctx.current_fn_bounds { inherited_bounds.push(bound) }
    ctx.current_fn_bounds = inherited_bounds

    let source_type_var_ids = exact_source_type_var_ids(
        registration_scheme, inherited_type_var_ids.len(), type_params.len())
    for index in 0..type_params.len() {
        let parameter = type_params.get(index).unwrap()
        let source_id = source_type_var_ids.get(index).unwrap()
        let variable = Type::TypeVar {
            id: source_id, name: some(parameter.name)
        }
        ctx.type_param_scope.insert(parameter.name, variable)
        ctx.env.bind_mono(parameter.name, variable)
    }

    for parameter in type_params {
        match ctx.type_param_scope.get(parameter.name) {
            some(Type::TypeVar { id, .. }) => {
                for bound in parameter.bounds {
                    let trait_name = resolve_trait_identity(
                        ctx, bound.trait_name)
                    let mut constraints: List<AssocConstraintEntry> = []
                    for constraint in bound.assoc_constraints {
                        constraints.push(AssocConstraintEntry {
                            name: constraint.name,
                            ty: resolve_type_expr(ctx, constraint.ty)
                        })
                    }
                    ctx.current_fn_bounds.push(FnBoundsEntry {
                        type_param_var_id: id,
                        trait_name: trait_name,
                        type_param_name: parameter.name,
                        dict_ordinal: ctx.current_fn_bounds.len(),
                        assoc_constraints: constraints
                    })
                    for supertrait in collect_all_supertraits(
                            ctx, trait_name) {
                        ctx.current_fn_bounds.push(FnBoundsEntry {
                            type_param_var_id: id,
                            trait_name: supertrait,
                            type_param_name: parameter.name,
                            dict_ordinal: ctx.current_fn_bounds.len(),
                            assoc_constraints: []
                        })
                    }
                }
            },
            _ => {}
        }
    }
    validate_fn_bound_order(ctx.current_fn_bounds)
    inject_assoc_types_from_bounds(ctx, type_params)

    let mut hparams: List<HParam> = []
    for index in 0..params.len() {
        let source = params.get(index).unwrap()
        let parameter_type = registered_params.get(index).unwrap()
        if source.name == "self" && source.type_annotation.is_none() {
            match self_type {
                some(expected_self) => {
                    ctx.subst = unify_at(
                        ctx.sink, ctx.env, parameter_type,
                        expected_self, ctx.subst, source.span)
                },
                none => {}
            }
        }
        ctx.env.bind_mono(source.name, parameter_type)
        let bound = ctx.env.lookup(source.name).unwrap_or_else(fn() {
            panic("function draft: parameter binding is absent")
        })
        match bound.def_id {
            some(def_id) => {
                journal_record_def_span(ctx, def_id, source.span)
                journal_var_lambda_depth_set(
                    ctx, def_id, ctx.lambda_depth)
                if source.is_mutable {
                    journal_mutable_var_insert(ctx, def_id)
                    journal_mut_param_def_insert(ctx, def_id)
                    if source.name != "self" &&
                       is_value_type(apply_subst(
                           ctx.subst, parameter_type)) {
                        journal_boxed_var_insert(ctx, def_id)
                    }
                } else {
                    journal_let_def_insert(ctx, def_id)
                }
            },
            none => {}
        }
        hparams.push(HParam {
            name: source.name, ty: parameter_type,
            def_id: bound.def_id, is_mutable: source.is_mutable
        })
    }

    ctx.current_fn_return_type = some(registered_return)
    let owner_declared_effects = if declared_effects.is_some() {
        some(registered_effects)
    } else {
        none
    }
    let inferred = infer_fn_body_constraints(
        ctx, provenance_key, registered_return,
        owner_declared_effects,
        if declared_effects.is_some() {
            none
        } else {
            some(registered_effects)
        },
        body, span)

    let complete_bounds = ctx.current_fn_bounds
    let raw_names = capture_raw_type_var_names(
        ctx, type_params, saved_tp_scope)
    let assoc_sources = capture_raw_assoc_rebind_sources(
        ctx, registration_scheme)
    let exact_type_params = exact_h_type_params(
        ctx, type_params, source_type_var_ids)
    let trait_bounds = materialize_trait_bounds(
        ctx, complete_bounds)
    let batch = detach_owner_batch(ctx, batch_checkpoint)
    FnDraft {
        name: name,
        executable: executable,
        impl_method_ref: impl_method_ref,
        registration_scheme: registration_scheme,
        inherited_type_var_ids: inherited_type_var_ids,
        source_type_var_ids: source_type_var_ids,
        is_pub: is_pub,
        span: span,
        type_params: exact_type_params,
        trait_bounds: trait_bounds,
        params: hparams,
        expected_return: registered_return,
        owner_effects: inferred.owner_effects,
        body: inferred.body,
        raw_type_var_names: raw_names,
        assoc_rebind_sources: assoc_sources,
        validation: validation,
        batch: batch
    }
    }) catch { _ => none }

    if ctx.env.scope.scopes.len() < env_scope_depth ||
       ctx.fn_bounds_stack.len() < fn_bounds_stack_depth {
        panic("function draft cleanup: transient stack underflow")
    }
    while ctx.env.scope.scopes.len() > env_scope_depth {
        ctx.env.pop_scope()
    }
    while ctx.fn_bounds_stack.len() > fn_bounds_stack_depth {
        ctx.fn_bounds_stack.pop()
    }
    ctx.current_fn_return_type = saved_fn_return
    ctx.type_param_scope = saved_tp_scope
    ctx.qualified_assoc_scope = saved_qualified_assoc
    ctx.current_fn_bounds = saved_fn_bounds

    match transaction {
        some(draft) => draft,
        none => fail.raise(CompileError {})
    }
}

fn check_fn_decl(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    params: List<Param>, return_type: TypeExpr?,
    declared_effects: List<EffectExpr>?, body: Expr,
    is_pub: Bool, span: Span, self_type: Type?,
    registration_override: TypeScheme?, rebind_identity: Str?,
    impl_method_ref: ImplMethodRef?, inherited_type_var_ids: List<Int>
) -> HDecl {
    let saved_subst = ctx.subst
    let diagnostic_checkpoint = ctx.sink.save()
    let mutation_checkpoint = begin_infer_mutation_journal(ctx)
    ctx.subst = empty_subst()
    let result = some({
        let draft = infer_fn_draft(
            ctx, name, type_params, params, return_type,
            declared_effects, body, is_pub, span, self_type,
            registration_override, rebind_identity, impl_method_ref,
            inherited_type_var_ids, FnValidationContext {
                capability: none, capability_span: none
            })
        finalize_singleton_fn_draft(
            ctx, draft, diagnostic_checkpoint)
    }) catch { _ => none }
    match result {
        some(hdecl) => {
            commit_infer_mutation_journal(ctx, mutation_checkpoint)
            ctx.subst = saved_subst
            hdecl
        },
        none => {
            rollback_infer_mutation_journal(ctx, mutation_checkpoint)
            ctx.subst = saved_subst
            fail.raise(CompileError {})
        }
    }
}
fn check_test_decl(
    mut ctx: InferCtx, description: Str, body: Expr, span: Span,
    decl_index: Int
) -> HDecl {
    let test_executable = test_executable_for_site(ctx, decl_index)
    let batch_checkpoint = owner_batch_checkpoint(ctx)
    enter_executable_owner(ctx, test_executable)
    let saved_subst = ctx.subst
    ctx.subst = empty_subst()
    ctx.env.push_scope()
    let body_result = some(infer_block(ctx, body, none)) catch { _ => none }
    let mut detached_batch: OwnerInferenceBatch? = none

    let final_body_unremapped = match body_result {
        some(br) => {
            ctx.subst = br.subst
            let batch = detach_owner_batch(ctx, batch_checkpoint)
            detached_batch = match some(drain_owner_batch_dictionaries(
                    ctx, batch, ctx.subst)) catch { _ => none } {
                some(value) => some(value),
                none => {
                    rollback_owner_batch(ctx, batch_checkpoint)
                    ctx.subst = saved_subst
                    ctx.env.pop_scope()
                    exit_executable_owner(ctx)
                    fail.raise(CompileError {})
                }
            }
            let zctx = ZonkCtx {
                subst: ctx.subst, names: map_new(),
                canonical_type_var_ids: map_new(),
                dict_resolver: none
            }
            zonk_block(zctx, br.hexpr)
        },
        none => {
            rollback_owner_batch(ctx, batch_checkpoint)
            ctx.subst = saved_subst
            // The scope must be restored before re-raising the declaration
            // error; the success path pops once below after value-zonk.
            ctx.env.pop_scope()
            exit_executable_owner(ctx)
            fail.raise(CompileError {})
        }
    }
    ctx.env.pop_scope()
    let final_batch_unstaged = match detached_batch {
        some(value) => value,
        none => panic("test owner batch: detached batch is absent")
    }
    let frozen_subst = ctx.subst
    let effect_schema = empty_typed_effect_header_schema()
    let callable_signature = Type::FnType {
        params: [], return_type: hexpr_type(final_body_unremapped),
        effects: hexpr_effects(final_body_unremapped)
    }
    let final_batch = stage_owner_batch_facts(
        ctx, final_batch_unstaged, test_executable,
        callable_signature, effect_schema, frozen_subst, map_new())
    let d1_checkpoint = ctx.sink.save()
    let final_body = finalize_effect_ctx_expr(
        ctx, FinalEffectCtxAuthority::FinalEffectCtxOwnerBatch(final_batch),
        final_body_unremapped)
    let effect_ctx = current_typed_callable_effect_ctx_from_owner_batch(
        ctx, final_batch, hexpr_effects(final_body))
    check_final_runtime_handled_contract(
        ctx, callable_signature, some(effect_ctx), "test", span)
    if diagnostics_since_has_errors(ctx, d1_checkpoint) {
        rollback_owner_batch(ctx, batch_checkpoint)
        ctx.subst = saved_subst
        exit_executable_owner(ctx)
        fail.raise(CompileError {})
    }
    preflight_owner_batches(ctx, [final_batch])
    publish_owner_batches(ctx, [final_batch])
    ctx.subst = saved_subst
    exit_executable_owner(ctx)

    HDecl::Test { description: description,
        executable_ref: test_executable,
        effect_ctx: effect_ctx,
        body: final_body, span: span }
}

// ============================================================
// Public entry point
// ============================================================

fn emit_checked_decl(
    mut ctx: InferCtx, decl: Decl, frame_decl_index: Int?,
    mut hdecls: List<HDecl>, cached_impls: List<CachedImplClose>,
    cached_values: List<CachedValueClose>
) {
    let hd = check_decl(
        ctx, decl, frame_decl_index, cached_impls, cached_values)
    let mut delegate_decls: List<HDecl> = []
    match decl {
        Decl::Impl { methods, .. } => {
            for source_member_index in 0..methods.len() {
                match methods.get(source_member_index) {
                    some(Decl::Delegate { field, span, .. }) => {
                        for expanded in expand_delegate_impls(
                                ctx, hd, source_member_index, field, span,
                                FnValidationContext {
                                    capability: none,
                                    capability_span: none
                                }) {
                            delegate_decls.push(expanded)
                        }
                    },
                    _ => {}
                }
            }
        },
        _ => {}
    }
    hdecls.push(hd)
    for expanded in delegate_decls { hdecls.push(expanded) }
}
fn infer_value_fn_draft(
    mut ctx: InferCtx, decl: Decl, validation: FnValidationContext
) -> FnDraft {
    match decl {
        Decl::Fn {
            name, type_params, params, return_type,
            declared_effects, body, is_pub, span, ..
        } => infer_fn_draft(
            ctx, name, type_params, params, return_type,
            declared_effects, body, is_pub, span,
            none, none, none, none, [], validation),
        _ => panic("value draft: declaration is not a function")
    }
}

fn infer_inline_draft_in_mod_body(
    mut ctx: InferCtx, mod_name: Str, uses: List<UseDecl>,
    decls: List<Decl>, required_effects: List<EffectExpr>?,
    module_span: Span, target_name: Str, project_frame_active: Bool,
    mut output: List<FnDraft>
) -> Bool {
    if !project_frame_active {
        insert_mod_aliases(ctx, mod_name, decls, false)
        resolve_mod_uses(ctx, uses, true)
    }
    let capability = required_effects.map(fn(values) {
        resolve_declared_effects(ctx, values)
    })
    match capability {
        some(row) => {
            ctx.mod_unsafe_allowed = row.effects.any(fn(eff) {
                match eff {
                    Effect::UnsafeEffect => true,
                    _ => false
                }
            })
        },
        none => { ctx.mod_unsafe_allowed = false }
    }
    let capability_span = capability.map(fn(_) { module_span })

    for decl_index in 0..decls.len() {
        let prefixed = prefix_decl_name(
            mod_name, decls.get(decl_index).unwrap())
        match prefixed {
            Decl::Fn { name, .. } => if name == target_name {
                output.push(infer_value_fn_draft(
                    ctx, prefixed, FnValidationContext {
                        capability: capability,
                        capability_span: capability_span
                    }))
                return true
            },
            Decl::ModBlock {
                name, uses: nested_uses, decls: nested_decls,
                required_effects: nested_required, span: nested_span, ..
            } => {
                if infer_inline_draft_in_mod(
                        ctx, name, nested_uses, nested_decls,
                        nested_required, nested_span,
                        target_name, decl_index, output) {
                    return true
                }
            },
            _ => {}
        }
    }
    false
}

fn infer_inline_draft_in_mod(
    mut ctx: InferCtx, mod_name: Str, uses: List<UseDecl>,
    decls: List<Decl>, required_effects: List<EffectExpr>?,
    module_span: Span, target_name: Str, frame_decl_index: Int,
    mut output: List<FnDraft>
) -> Bool {
    enter_impl_check_child_frame(ctx, frame_decl_index)
    let project_active = ctx.project_namespace_file_key.is_some()
    let mut entered_project_frame = false
    if project_active {
        entered_project_frame = enter_project_child_frame(
            ctx, frame_decl_index)
        if !entered_project_frame {
            exit_impl_check_frame(ctx)
            panic("unreachable: resolver plan missing inline draft frame")
        }
    }
    let segments = mod_name.split("::")
    let simple_name = segments.get(segments.len() - 1).unwrap_or(mod_name)
    ctx.mod_path_stack.push(simple_name)
    let previous_unsafe = ctx.mod_unsafe_allowed
    let result = infer_inline_draft_in_mod_body(
        ctx, mod_name, uses, decls, required_effects,
        module_span, target_name, project_active, output) catch { _ => {
            ctx.mod_unsafe_allowed = previous_unsafe
            let _ = ctx.mod_path_stack.pop()
            if entered_project_frame {
                let _ = exit_project_namespace_frame(ctx)
            }
            exit_impl_check_frame(ctx)
            fail.raise(CompileError {})
        }
    }
    ctx.mod_unsafe_allowed = previous_unsafe
    let _ = ctx.mod_path_stack.pop()
    if entered_project_frame {
        let _ = exit_project_namespace_frame(ctx)
    }
    exit_impl_check_frame(ctx)
    result
}

fn infer_inline_value_draft(
    mut ctx: InferCtx, decls: List<Decl>, target_name: Str
) -> FnDraft {
    let mut output: List<FnDraft> = []
    for decl_index in 0..decls.len() {
        match decls.get(decl_index).unwrap() {
            Decl::ModBlock {
                name, uses, decls: mod_decls,
                required_effects, span, ..
            } => {
                if infer_inline_draft_in_mod(
                        ctx, name, uses, mod_decls, required_effects,
                        span, target_name, decl_index, output) {
                    break
                }
            },
            _ => {}
        }
    }
    if output.len() != 1 {
        panic("inline value draft: exact member is absent")
    }
    output.get(0).unwrap()
}
fn value_dependency_closure(
    graph: Map<Str, List<Str>>, roots: Set<Str>
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
                        if !dep.starts_with("impl::") &&
                           !closure.contains(dep) {
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

fn scc_group_is_recursive(
    group: List<Str>, graph: Map<Str, List<Str>>
) -> Bool {
    if group.len() > 1 { return true }
    match group.get(0) {
        some(member) => match graph.get(member) {
            some(edges) => edges.contains(member),
            none => false
        },
        none => false
    }
}

fn value_callable_executable(
    ctx: InferCtx, name: Str
) -> ExecutableRef {
    let scheme = ctx.env.lookup(name).unwrap_or_else(fn() {
        panic("recursive callable group: registered value is absent")
    })
    named_executable_for_def_id(
        ctx, scheme.def_id, "recursive function '${name}'")
}

fn executable_group_contains(
    values: List<ExecutableRef>, wanted: ExecutableRef
) -> Bool {
    for value in values {
        if executable_ref_same(value, wanted) { return true }
    }
    false
}

fn scheme_is_recursive_group_member(
    ctx: InferCtx, scheme: TypeScheme,
    executables: List<ExecutableRef>
) -> Bool {
    match scheme.def_id {
        some(def_id) => match ctx.value_symbols.get(def_id) {
            some(symbol) => executable_group_contains(
                executables, make_named_executable_ref(symbol)),
            none => false
        },
        none => false
    }
}

// HM generalization for a recursive value group is relative to the environment
// outside that group. Alias bindings whose exact executable is a member are
// excluded together with the canonical binding; all other lexical values stay
// visible as the external monomorphic boundary.
fn free_type_vars_outside_recursive_group(
    ctx: InferCtx, executables: List<ExecutableRef>, subst: UnionFind
) -> Set<Int> {
    let mut result: Set<Int> = set_new()
    for scope in ctx.env.scope.scopes {
        let mut bindings = scope.variables.entries()
        bindings.sort_by(compare_by_first)
        for entry in bindings {
            let (_, scheme) = entry
            if scheme_is_recursive_group_member(
                    ctx, scheme, executables) { continue }
            let free = free_type_vars(scheme.ty, subst)
            let mut quantified: Set<Int> = set_new()
            for source in scheme.type_vars {
                match apply_subst(
                        subst,
                        Type::TypeVar { id: source, name: none }) {
                    Type::TypeVar { id, .. } => { quantified.insert(id) },
                    _ => { quantified.insert(source) }
                }
            }
            for id in free {
                if !quantified.contains(id) { result.insert(id) }
            }
        }
    }
    result
}

fn infer_and_commit_value_draft_group(
    mut ctx: InferCtx, decls: List<Decl>, group: List<Str>,
    top_level_indices: Map<Str, Int>, recursive: Bool,
    mut cached_values: List<CachedValueClose>
) {
    let mut names = group.filter(fn(name) {
        !name.starts_with("impl::")
    })
    names.sort()
    if names.len() == 0 { return }

    let mut executables: List<ExecutableRef> = []
    for name in names {
        executables.push(value_callable_executable(ctx, name))
    }
    let saved_subst = ctx.subst
    let diagnostic_checkpoint = ctx.sink.save()
    let mutation_checkpoint = begin_infer_mutation_journal(ctx)
    ctx.subst = empty_subst()
    if recursive {
        begin_recursive_callable_group(ctx, executables)
    }
    let result = some({
        let mut drafts: List<FnDraft> = []
        for name in names {
            match top_level_indices.get(name) {
                some(index) => match decls.get(index) {
                    some(decl) => drafts.push(infer_value_fn_draft(
                        ctx, decl, FnValidationContext {
                            capability: none, capability_span: none
                        })),
                    none => panic(
                        "value draft group: top-level member is absent")
                },
                none => drafts.push(infer_inline_value_draft(
                    ctx, decls, name))
            }
        }
        if diagnostics_since_has_errors(ctx, diagnostic_checkpoint) {
            fail.raise(CompileError {})
        }
        let prepared = prepare_fn_draft_group(
            ctx, drafts, executables, diagnostic_checkpoint)
        preflight_value_draft_group(ctx, prepared)
        prepared
    }) catch { _ => none }

    match result {
        some(prepared) => {
            if recursive {
                end_recursive_callable_group(ctx, executables)
            }
            let declarations = commit_value_draft_group(ctx, prepared)
            for index in 0..declarations.len() {
                cached_values.push(CachedValueClose {
                    executable: executables.get(index).unwrap(),
                    declaration: declarations.get(index).unwrap()
                })
            }
            commit_infer_mutation_journal(ctx, mutation_checkpoint)
            if recursive {
                mark_recursive_callable_group_closed(ctx, executables)
            }
            ctx.subst = saved_subst
        },
        none => {
            if recursive {
                end_recursive_callable_group(ctx, executables)
            }
            rollback_infer_mutation_journal(ctx, mutation_checkpoint)
            ctx.subst = saved_subst
            fail.raise(CompileError {})
        }
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
                                effect_schema: scheme.effect_schema,
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
    let derived_impls = run_derive_pass(ctx)
    for derived in derived_impls {
        for method in derived.methods {
            publish_exact_callable_effect_header(
                ctx, method.executable_ref, method.signature,
                empty_typed_effect_header_schema())
        }
    }
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
    // B-122: Build SCC for fn/impl declaration ordering.
    // Callees are checked before callers so that rebinding makes resolved
    // return types visible to callers (fixing the #149 unsound ret-var hole).
    let registered_fns = collect_registered_fn_names(program.decls)
    let call_graph = build_call_graph(program.decls, registered_fns)
    let scc_groups = tarjan_scc(call_graph)

    let mut fn_name_to_idx: Map<Str, Int> = map_new()
    for index in 0..program.decls.len() {
        match program.decls.get(index).unwrap() {
            Decl::Fn { name, .. } => fn_name_to_idx.insert(name, index),
            _ => {}
        }
    }

    let mut impl_roots: Set<Str> = set_new()
    for node in call_graph.keys() {
        if node.starts_with("impl::") { impl_roots.insert(node) }
    }
    let impl_dependencies = value_dependency_closure(
        call_graph, impl_roots)
    let mut cached_impls: List<CachedImplClose> = []
    let mut cached_values: List<CachedValueClose> = []
    let mut finalized_values: Set<Str> = set_new()

    // Exact value dependencies of impl bodies close leaf-first first. Method
    // calls have no resolver-safe AST edge, so all remaining values wait until
    // the retained impl cache is complete.
    for group in scc_groups {
        let mut needed = false
        for name in group {
            if !name.starts_with("impl::") &&
               impl_dependencies.contains(name) {
                needed = true
            }
        }
        if needed {
            infer_and_commit_value_draft_group(
                ctx, program.decls, group, fn_name_to_idx,
                scc_group_is_recursive(group, call_graph), cached_values)
            for name in group {
                if !name.starts_with("impl::") {
                    finalized_values.insert(name)
                }
            }
        }
    }

    prepare_impl_close_cache(ctx, program.decls, cached_impls)

    for group in scc_groups {
        let mut pending = false
        for name in group {
            if !name.starts_with("impl::") &&
               !finalized_values.contains(name) {
                pending = true
            }
        }
        if pending {
            infer_and_commit_value_draft_group(
                ctx, program.decls, group, fn_name_to_idx,
                scc_group_is_recursive(group, call_graph), cached_values)
            for name in group {
                if !name.starts_with("impl::") {
                    finalized_values.insert(name)
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
                let result = some(emit_checked_decl(
                    ctx, decl, some(di), hdecls,
                    cached_impls, cached_values)) catch { _ => none }
                checked.insert(di)
            }
        }
        di = di + 1
    }

    // Phase 2a: Check impl blocks in source order (before top-level fns).
    // Each impl closes its internal method SCCs leaf-first before returning,
    // so top-level callers only observe final method schemes/headers.
    let mut ii = 0
    for decl in program.decls {
        match decl {
            Decl::Impl { .. } => {
                if !checked.contains(ii) {
                    let owner_ref = impl_check_owner(ctx, ii)
                    let cached = cached_impl_declarations(
                        cached_impls, owner_ref).unwrap_or_else(fn() {
                        panic("impl close cache: root owner is absent")
                    })
                    for hdecl in cached { hdecls.push(hdecl) }
                    checked.insert(ii)
                }
            },
            _ => {}
        }
        ii = ii + 1
    }

    // Phase 2b: emit each already-finalized top-level function exactly once.
    for scc_group in scc_groups {
        for name in scc_group {
            match fn_name_to_idx.get(name) {
                some(i) => {
                    if !checked.contains(i) {
                        match program.decls.get(i) {
                            some(decl) => {
                                let _ = decl
                                let executable = value_callable_executable(
                                    ctx, name)
                                let hdecl = cached_value_declaration(
                                    cached_values, executable).unwrap_or_else(
                                        fn() {
                                    panic("top-level HIR cache: final function is absent")
                                })
                                hdecls.push(hdecl)
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
            let result = some(emit_checked_decl(
                ctx, decl, some(ri), hdecls,
                cached_impls, cached_values)) catch { _ => none }
        }
        ri = ri + 1
    }

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
    mut ctx: InferCtx, decl: Decl, file_key: Str, decl_index: Int,
    final_extern_symbol: SymbolRef?
) -> HDecl {
    // Note: check_decl uses fail.raise internally. Due to the known limitation
    // where cross-module effect propagation doesn't work (effects registered as
    // EMPTY_ROW in Pass 1), we must explicitly surface the fail effect here so
    // callers pass the __ring_ev_fail evidence.
    enter_impl_check_root_frame(ctx, file_key)
    match final_extern_symbol {
        some(symbol) => match decl {
            Decl::ExternFn { name, .. } =>
                commit_final_prelude_value_symbol_ref(ctx, name, symbol),
            _ => panic("prelude final extern symbol attached to non-extern")
        },
        none => {}
    }
    let result = some(check_decl(
        ctx, decl, some(decl_index), [], [])) catch { _ => {
        exit_impl_check_frame(ctx)
        fail.raise(CompileError {})
    } }
    exit_impl_check_frame(ctx)
    if false { fail.raise(CompileError {}) }
    result.unwrap()
}
