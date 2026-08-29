// C-native expression and statement emission.
//
// Emission protocol: gen_c_expr emits C statements into ctx.cur_body and
// returns a C expression string holding the value.  Pure constants (Int/Bool
// literals, RING_UNIT) are returned inline; everything else is materialised
// into a hoisted temporary so evaluation order stays explicit and deterministic.
//
// Step 4 adds struct/enum construction, field access/assignment, match and
// if-let.  Match compiles through ONE unified test-and-fall-through chain —
// a test-and-fall-through lowering.  Arm order = source order,
// pattern tests jump to the next arm's label on mismatch (if/goto+label).
//
// Step 6 adds explicit custom-effect handlers (tail-resumptive + abort) and
// try/catch; Ring 0.1 has no default handled-effect context path.
//
use types::{Type, EMPTY_ROW, type_to_builtin_name, types_equal}
use env::{TypeScheme}
use ast::{BinOp, UnaryOp, Pattern, LiteralValue, NamedPatternField, Span}
use hir::{HExpr, HStmt, HParam, HMatchArm, HStringInterpPart,
    HLetDestructureBinding, HPatternBinding, HStructFieldInit,
    HNominalStructFieldInit, HFieldAccessKind,
    HEffectHandler, HConstructorPlan, DictRef,
    h_dict_construct_effect_ctx,
    h_constructor_kind, h_constructor_fields,
    h_projection_kind, h_projection_variant,
    TraitDispatch, MethodCallRef,
    method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_is_bound,
    method_call_ref_intrinsic, method_call_ref_impl,
    method_call_ref_bound, method_call_ref_bound_evidence,
    method_call_ref_signature,
    hexpr_type, hexpr_effects, is_fresh_owned_bool_value, compare_by_first,
    trait_bound_param_name,
    is_extern_handle_type,
    slot_bridge_runtime_name, is_synthetic_dict_def_id}
use hir_exact::{
    h_dict_construct_base, h_dict_construct_inner,
    dict_ref_exact,
    dict_ref_is_simple_physical, dict_ref_is_static_physical,
    dict_ref_simple_name,
    dict_ref_wrapped_physical_inner
}
use ir_inventory::{ExactDictRef,
    dict_ref_is_static, dict_ref_is_wrapped,
    dict_ref_static, dict_ref_wrapped_base, dict_ref_wrapped_inner,
    dict_ref_same, make_exact_wrapped_dict_ref,
    EffectCtxRef, EffectCtxParentCapture, SystemHostCallableRef,
    EffectOperationRef, make_named_executable_ref,
    executable_ref_same,
    effect_ctx_slot,
    effect_ctx_parent_capture_source, effect_ctx_parent_capture_target,
    effect_operation_ref_effect,
    effect_operation_ref_source_index}
use effect_contract::{TypedHandledEffectInstance,
    TypedCallableEffectCtx, TypedEffectCtxSource,
    TypedEffectCtxLookup, TypedEffectCtxInstall,
    typed_callable_effect_ctx_binding,
    typed_effect_ctx_source_is_empty, typed_effect_ctx_source_context,
    make_empty_effect_ctx_source,
    typed_effect_ctx_lookup_context, typed_effect_ctx_lookup_instance,
    typed_effect_ctx_install_parent, typed_effect_ctx_install_child,
    typed_effect_ctx_install_entries,
    typed_handled_effect_instance_reference,
    typed_handled_effect_instance_same}
use legacy_projection::{
    legacy_effect_ctx_token_ordinal, legacy_effect_ctx_token_instance}
use extern_manifest::{HostImportFact,
    host_import_fact_for_extern, host_import_fact_for_declaration,
    host_import_fact_host, host_import_fact_callable_signature,
    host_import_fact_native_target,
    host_import_fact_lowering, host_import_lowering_tag,
    HOST_IMPORT_BOXED_DIRECT, HOST_IMPORT_PRINT_VALUE,
    HOST_IMPORT_ASSERT_CONDITION,
    compiler_extern_ref_for_executable}
use builtins::{BuiltinValueContractFact,
    builtin_value_contract_facts, builtin_value_contract_site,
    builtin_value_contract_executable, builtin_value_contract_symbol,
    builtin_value_contract_scheme, builtin_value_contract_physical,
    builtin_value_physical_lowering_tag,
    builtin_value_physical_lowering_data,
    BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME,
    BUILTIN_VALUE_PHYSICAL_PTR_FROM_ADDR,
    BUILTIN_VALUE_PHYSICAL_HASH_COMBINE,
    BUILTIN_VALUE_PHYSICAL_STR_IDENTITY,
    BUILTIN_VALUE_PHYSICAL_BOOL_TO_STR,
    BUILTIN_VALUE_PHYSICAL_INDEX}
use ir_identity::{CalleeRef, SlotRef, SymbolRef, ImplOwnerRef, ImplMethodRef,
    VariantRef,
    callee_ref_is_named, callee_ref_named_symbol,
    compiler_extern_ref_site, compiler_extern_site_tag,
    path_owner_for_symbol, make_path_ref, path_role_synthetic,
    make_synthetic_slot_ref, slot_ref_stable_key,
    builtin_method_site_tag, intrinsic_ref_site,
    slot_ref_is_source, slot_ref_source_def_id, slot_ref_same,
    handled_effect_ref_same,
    impl_method_ref_stable_key,
    trait_method_ref_callable_slot_index,
    impl_owner_ref_same, impl_owner_ref_provider,
    impl_provider_ref_kind, impl_provider_kind_builtin,
    impl_provider_kind_same,
    symbol_ref_origin_module_key, symbol_ref_canonical_payload,
    symbol_ref_same,
    variant_ref_owner, variant_ref_source_index, variant_ref_same,
    variant_field_ref_variant, variant_field_ref_index,
    variant_field_ref_same,
    registered_nominal_ref_display_name,
    builtin_option_none_variant_ref,
    BUILTIN_METHOD_STR_LEN, BUILTIN_METHOD_STR_CONTAINS,
    BUILTIN_METHOD_STR_STARTS_WITH, BUILTIN_METHOD_STR_ENDS_WITH,
    BUILTIN_METHOD_STR_SLICE, BUILTIN_METHOD_STR_TRIM,
    BUILTIN_METHOD_STR_TO_UPPER, BUILTIN_METHOD_STR_TO_LOWER,
    BUILTIN_METHOD_STR_REPLACE, BUILTIN_METHOD_STR_SPLIT,
    BUILTIN_METHOD_STR_CHAR_AT, BUILTIN_METHOD_STR_INDEX_OF,
    BUILTIN_METHOD_STR_PAD_START, BUILTIN_METHOD_STR_PAD_END,
    BUILTIN_METHOD_STR_REPEAT, BUILTIN_METHOD_STR_CHAR_CODE_AT,
    BUILTIN_METHOD_STR_TRIM_START, BUILTIN_METHOD_STR_TRIM_END,
    BUILTIN_METHOD_STR_IS_EMPTY, BUILTIN_METHOD_STR_LAST_INDEX_OF,
    BUILTIN_METHOD_INT_TO_STR, BUILTIN_METHOD_FLOAT_TO_STR,
    BUILTIN_METHOD_OPTION_UNWRAP_OR, BUILTIN_METHOD_OPTION_UNWRAP,
    BUILTIN_METHOD_OPTION_IS_SOME, BUILTIN_METHOD_OPTION_IS_NONE,
    BUILTIN_METHOD_OPTION_MAP, BUILTIN_METHOD_OPTION_AND_THEN,
    BUILTIN_METHOD_OPTION_UNWRAP_OR_ELSE, BUILTIN_METHOD_OPTION_TO_FAIL,
    BUILTIN_METHOD_CELL_GET, BUILTIN_METHOD_CELL_SET,
    BUILTIN_METHOD_CELL_UPDATE, COMPILER_EXTERN_LIST_SORT,
    BUILTIN_METHOD_INT_EQ, BUILTIN_METHOD_INT_NE,
    BUILTIN_METHOD_FLOAT_EQ, BUILTIN_METHOD_FLOAT_NE,
    BUILTIN_METHOD_STR_EQ, BUILTIN_METHOD_STR_NE,
    BUILTIN_METHOD_BOOL_EQ, BUILTIN_METHOD_BOOL_NE,
    BUILTIN_METHOD_INT_CLONE, BUILTIN_METHOD_FLOAT_CLONE,
    BUILTIN_METHOD_STR_CLONE, BUILTIN_METHOD_BOOL_CLONE,
    BUILTIN_METHOD_INT_CMP, BUILTIN_METHOD_FLOAT_CMP,
    BUILTIN_METHOD_STR_CMP, BUILTIN_METHOD_BOOL_CMP,
    BUILTIN_METHOD_INT_DEBUG, BUILTIN_METHOD_FLOAT_DEBUG,
    BUILTIN_METHOD_STR_DEBUG, BUILTIN_METHOD_BOOL_DEBUG,
    BUILTIN_METHOD_INT_HASH, BUILTIN_METHOD_STR_HASH,
    BUILTIN_METHOD_BOOL_HASH,
    BUILTIN_METHOD_PTR_ADDR, BUILTIN_METHOD_PTR_CAST,
    BUILTIN_METHOD_PTR_OFFSET, BUILTIN_METHOD_PTR_READ,
    BUILTIN_METHOD_PTR_TAKE, BUILTIN_METHOD_PTR_WRITE,
    BUILTIN_METHOD_SITE_COUNT,
    builtin_value_site_tag,
    BUILTIN_VALUE_CELL_CONSTRUCTOR, BUILTIN_VALUE_ALLOC,
    BUILTIN_VALUE_DEALLOC, BUILTIN_VALUE_PTR_COPY,
    BUILTIN_VALUE_PTR_FROM_ADDR, BUILTIN_VALUE_HASH_COMBINE,
    BUILTIN_VALUE_STR_IDENTITY, BUILTIN_VALUE_BOOL_TO_STR,
    BUILTIN_VALUE_LIST_INDEX, BUILTIN_VALUE_STR_INDEX,
    BUILTIN_VALUE_SITE_COUNT}
use codegen_c_ctx::{CCtx, CFnInfo, CStructInfo, CEnumInfo, CEnumVariantInfo,
    CEmitState, CHandleCleanup,
    CNameOnlySlotRef, CTypedRef, CClosureEdge,
    c_emit, c_raw, fresh_tmp, fresh_i64, fresh_dbl, fresh_label,
    c_local, c_local_ref, c_local_def, c_local_def_ref,
    c_param, c_param_def, c_value_slot, c_exact_value_slot,
    c_local_semantic_slot, c_semantic_value_slot,
    c_local_effect_ctx_slot, c_param_effect_ctx_slot,
    c_exact_slot_c_name, c_name_only_slot_c_name, c_name_only_slot_key,
    c_register_name_only_value, c_restore_name_only_value, c_remove_name_only_value,
    c_name_only_value, c_ref_exact, c_ref_name_only, c_ref_static,
    c_ref_computed, c_ref_fresh, c_ref_loaded,
    c_ref_c_name, c_ref_domain, c_ref_def_id, c_ref_key,
    c_new_closure_edge, c_fresh_load_id,
    c_record_capture_extract, c_record_capture_store, c_record_closure_edge,
    c_record_receiver_load, c_record_closure_call, c_mangle_fn,
    c_effect_ctx_token_symbol,
    c_resolve_fn,
    c_exact_method_info, c_exact_method_for_owner_slot,
    c_exact_method_count_for_owner, c_method_info_fn,
    c_trait_dict_physical_key, c_static_dict_physical_key,
    c_builtin_trait_dict_abi_name, c_trait_dict_build_symbol,
    c_static_dict_getter_symbol, c_static_dict_global_symbol,
    c_sanitize, c_global_cstr, c_interned_cstr, c_stub_stmt, c_stub_expr,
    c_line_directive, rt_use, rt_use_raw, rt_known_arity,
    get_or_assign_c_typeid,
    fresh_effect_ctx_token_array, fresh_effect_ctx_evidence_array,
    c_push_fn, c_pop_fn}

// ============================================================
// Type predicate helpers
// ============================================================

fn is_int_type(ty: Type) -> Bool {
    match ty { Type::IntType => true, _ => false }
}

fn is_float_type(ty: Type) -> Bool {
    match ty { Type::FloatType => true, _ => false }
}

fn is_str_type(ty: Type) -> Bool {
    match ty { Type::StrType => true, _ => false }
}

fn is_bool_type(ty: Type) -> Bool {
    match ty { Type::BoolType => true, _ => false }
}

fn is_unit_type(ty: Type) -> Bool {
    match ty { Type::UnitType => true, _ => false }
}

// B-134 port: structural validation for builtin collection dispatch.
fn is_builtin_collection(ty: Type) -> Bool {
    match ty {
        Type::StructType { name, type_params } => {
            if name == "List" { type_params.len() == 1 }
            else if name == "Map" { type_params.len() == 2 }
            else if name == "Set" { type_params.len() == 1 }
            else { false }
        },
        _ => false,
    }
}

fn is_boxed_def_c(ctx: CCtx, def_id: Int?) -> Bool {
    match def_id {
        some(did) => ctx.boxed_vars.contains(did),
        none => false,
    }
}

fn c_effect_ctx_ref(ctx: CCtx, value: EffectCtxRef) -> CTypedRef {
    match c_semantic_value_slot(ctx, effect_ctx_slot(value)) {
        some(slot) => c_ref_exact(slot),
        none => panic("C codegen: exact EffectCtx slot is absent")
    }
}

fn c_effect_ctx_source_value(
    mut ctx: CCtx, source: TypedEffectCtxSource
) -> Str {
    if typed_effect_ctx_source_is_empty(source) {
        rt_use(ctx, "ring_effect_ctx_empty", 0)
        "ring_effect_ctx_empty()"
    } else {
        c_ref_c_name(c_effect_ctx_ref(
            ctx, typed_effect_ctx_source_context(source)))
    }
}

fn c_effect_ctx_token_value(
    ctx: CCtx, instance: TypedHandledEffectInstance
) -> Str {
    let mut found: Int? = none
    for token in ctx.effect_ctx_tokens {
        if typed_handled_effect_instance_same(
                legacy_effect_ctx_token_instance(token), instance) {
            match found {
                some(_) => panic(
                    "C codegen: EffectCtx sidecar instance repeats"),
                none => { found = some(
                    legacy_effect_ctx_token_ordinal(token)) }
            }
        }
    }
    match found {
        some(ordinal) =>
            "((const void*)&${c_effect_ctx_token_symbol(ordinal)})",
        none => panic("C codegen: EffectCtx sidecar instance is absent")
    }
}

fn c_compiler_extern_tag(callee_ref: CalleeRef?) -> Int? {
    match callee_ref {
        some(reference) => if callee_ref_is_named(reference) {
            match compiler_extern_ref_for_executable(
                    make_named_executable_ref(
                        callee_ref_named_symbol(reference))) {
                some(extern_ref) => some(compiler_extern_site_tag(
                    compiler_extern_ref_site(extern_ref))),
                none => none
            }
        } else {
            none
        },
        none => none
    }
}

fn c_compiler_extern_forwards_ctx(callee_ref: CalleeRef?) -> Bool {
    match c_compiler_extern_tag(callee_ref) {
        some(tag) => tag == COMPILER_EXTERN_LIST_SORT,
        none => false
    }
}

// ============================================================
// Main expression dispatch
// ============================================================

pub fn gen_c_expr(mut ctx: CCtx, expr: HExpr) -> Str {
    match expr {
        HExpr::IntLit { value, .. } => "RING_INT(${value})",
        HExpr::FloatLit { value, .. } => {
            rt_use(ctx, "ring_box_float", 1)
            let t = fresh_tmp(ctx)
            // Float→text via the runtime's shortest-round-trip formatter
            // (ring_float_to_str semantics); C's decimal→double conversion
            // reads it back to the identical IEEE value.
            c_emit(ctx, "${t} = ring_box_float(${value});")
            t
        },
        HExpr::StrLit { value, .. } => gen_c_str_lit(ctx, value),
        HExpr::BoolLit { value, .. } => if value { "RING_TRUE" } else { "RING_FALSE" },
        HExpr::Ident { name, resolved_name, def_id, callee_identity,
                       dict_closure_dicts, ty, span, .. } =>
            gen_c_ident(ctx, name, resolved_name, def_id, callee_identity,
                dict_closure_dicts, ty, span),
        HExpr::BinOp { op, left, right, eq_dispatch, ord_dispatch, ty, .. } =>
            gen_c_binop(ctx, op, left, right, eq_dispatch, ord_dispatch, ty),
        HExpr::UnaryOp { op, operand, ty, .. } => gen_c_unaryop(ctx, op, operand, ty),
        HExpr::Call { callee, args, resolved_dicts, effect_ctx,
                      callee_ref, method_ref, system_host, ty, .. } =>
            gen_c_call(
                ctx, callee, args, resolved_dicts,
                effect_ctx, callee_ref, method_ref, system_host, ty),
        HExpr::FieldAccess { receiver, field, access_kind, ty, .. } =>
            gen_c_field_access(ctx, receiver, field, access_kind, ty),
        HExpr::StructLit { name, fields, spread, constructor, .. } =>
            gen_c_struct_lit(ctx, name, fields, spread, constructor),
        HExpr::NamedVariantConstruct { enum_name, variant_name, variant_ref,
                                       fields,
                                       spread, constructor, .. } =>
            gen_c_variant_construct(
                ctx, enum_name, variant_name, variant_ref,
                fields, spread, constructor),
        HExpr::MatchExpr { scrutinee, arms, .. } =>
            gen_c_match_expr(ctx, scrutinee, arms),
        HExpr::Block { stmts, tail, .. } => gen_c_block(ctx, stmts, tail),
        HExpr::IfExpr { condition, then_branch, else_branch, .. } =>
            gen_c_if_expr(ctx, condition, then_branch, else_branch),
        HExpr::StringInterp { parts, .. } => gen_c_string_interp(ctx, parts),
        HExpr::TryCatch { body, arms, .. } => gen_c_try_catch(ctx, body, arms),
        HExpr::HandleExpr { body, handlers, effect_ctx_install, .. } =>
            gen_c_handle_expr(ctx, body, handlers, effect_ctx_install),
        HExpr::Lambda { params, return_type, body, ty, effect_ctx, .. } =>
            gen_c_lambda(
                ctx, params, return_type, body, ty, effect_ctx),
        HExpr::EffectOp { effect_name, op_name, operation_ref,
                          effect_ctx_lookup, args, .. } =>
            gen_c_effect_op(ctx, effect_name, op_name, operation_ref,
                effect_ctx_lookup, args),
        HExpr::ListLit { .. } => panic(
            "C codegen: List surface literal crossed PreCore"),
        HExpr::TupleLit { elements, .. } => gen_c_tuple_lit(ctx, elements),
        HExpr::IndexExpr { receiver, index, .. } => gen_c_index_expr(ctx, receiver, index),
        // B-104 D4: local construction of a DYNAMIC wrapped dict (dict_lower's
        // `let __ring_dictlocal_N = …` init) — a fresh owned value, reclaimed
        // by the binding's Perceus scope-end drop.
        HExpr::DictConstruct { plan, inner, .. } => {
            let exact = match plan {
                some(value) => value,
                none => panic("C codegen: dictionary construct lacks exact plan")
            }
            let _ = h_dict_construct_effect_ctx(exact)
            let exact_dict = make_exact_wrapped_dict_ref(
                h_dict_construct_base(exact), h_dict_construct_inner(exact))
            build_c_wrapped_dict(ctx, inner, exact_dict)
        },
        HExpr::Clone { inner, .. } => {
            // Perceus value-level clone: eval, ring_dup, yield the same ptr.
            let v = gen_c_expr(ctx, inner)
            rt_use(ctx, "ring_dup", 1)
            c_emit(ctx, "ring_dup(${v});")
            v
        },
        HExpr::Take { source, saved_slot, .. } => {
            let _ = saved_slot
            match source {
                HExpr::Ident { name, def_id: some(def_id), .. } => match
                        c_exact_value_slot(ctx, name, def_id) {
                    some(slot) => {
                        let source_name = c_exact_slot_c_name(slot)
                        let saved = fresh_tmp(ctx)
                        c_emit(ctx, "${saved} = ${source_name};")
                        c_emit(ctx, "${source_name} = RING_NULL;")
                        saved
                    },
                    none => panic(
                        "C codegen: Take source has no exact physical slot")
                },
                HExpr::FieldAccess { receiver, field, access_kind, .. } => {
                    reject_c_error_field_access(access_kind)
                    let recv_type = hexpr_type(receiver)
                    let recv_val = gen_c_expr(ctx, receiver)
                    let type_name = match recv_type {
                        Type::StructType { name, .. } => name,
                        Type::EnumType { name, .. } => name,
                        _ => panic("C codegen: projected Take base is not nominal")
                    }
                    let info = ctx.struct_types.get(type_name).unwrap_or_else(fn() {
                        panic("C codegen: projected Take nominal is unregistered")
                    })
                    let mut field_index = -1
                    for index in 0..info.field_names.len() {
                        if info.field_names[index] == field { field_index = index }
                    }
                    if field_index < 0 {
                        panic("C codegen: projected Take field is absent")
                    }
                    let saved = fresh_tmp(ctx)
                    c_emit(ctx, "${saved} = ((void**)${recv_val})[${field_index}];")
                    c_emit(ctx, "((void**)${recv_val})[${field_index}] = RING_NULL;")
                    saved
                },
                _ => panic("C codegen: Take source is not an exact slot/place")
            }
        },
        HExpr::UnsafeBlock { body, .. } => gen_c_expr(ctx, body),
        HExpr::ReturnExpr { value, .. } => {
            // return in expression position (B-113).  #173/#193: walk the
            // handle/try cleanup stack before returning (same order as the
            // LLVM backend: cleanup first, then evaluate the value).
            emit_c_cleanup_walk(ctx)
            match value {
                some(v) => {
                    let val = gen_c_expr(ctx, v)
                    c_emit(ctx, "return ${val};")
                },
                none => c_emit(ctx, "return RING_UNIT;"),
            }
            // Unreachable placeholder (any following C statements are dead).
            "RING_UNIT"
        },
    }
}

fn gen_c_str_lit(mut ctx: CCtx, value: Str) -> Str {
    let g = c_global_cstr(ctx, value)
    rt_use(ctx, "ring_str_from_cstr", 1)
    let t = fresh_tmp(ctx)
    c_emit(ctx, "${t} = ring_str_from_cstr(${g});")
    t
}

// ============================================================
// Step 8: exact module-aware function lookup.
// ============================================================

struct CFnLookup {
    fi: CFnInfo,
    key: Str
}

fn c_lookup_key(ctx: CCtx, key: Str) -> CFnLookup? {
    match ctx.functions.get(key) {
        some(fi) => some(CFnLookup { fi: fi, key: key }),
        none => none,
    }
}

// Precise function lookup. Checker HIR carries the exact canonical origin;
// backend-wide prefix/suffix scans would silently select the wrong module.
fn c_find_fn_precise(ctx: CCtx, name: Str) -> CFnLookup? {
    // 1. Precise match via c_resolve_fn (imports_map, module_prefix, bare)
    let resolved = c_resolve_fn(ctx, name)
    match c_lookup_key(ctx, resolved) {
        some(r) => { return some(r) },
        none => {},
    }
    // 2. Bare mangling (builtins / unqualified names)
    match c_lookup_key(ctx, c_mangle_fn(name)) {
        some(r) => { return some(r) },
        none => {},
    }
    none
}

// Multi-strategy lookup given an already-resolved key + the source name.
fn c_find_function_in_ctx(ctx: CCtx, mangled: Str, name: Str) -> CFnLookup? {
    match c_lookup_key(ctx, mangled) {
        some(r) => some(r),
        none => {
            match c_lookup_key(ctx, c_mangle_fn(name)) {
                some(r) => some(r),
                none => c_find_fn_precise(ctx, name),
            }
        },
    }
}

// ============================================================
// Identifiers
// ============================================================

fn gen_c_ident(
    mut ctx: CCtx, name: Str, resolved_name: Str?, def_id: Int?,
    callee_identity: CalleeRef?, dict_closure_dicts: List<DictRef>?,
    ty: Type, span: Span
) -> Str {
    // #B-087 gap 1: a polymorphic function used as a first-class value carries
    // dict_closure_dicts (the resolved trait dicts for its bounds).  Build a
    // {thunk, env} closure whose env captures only the dictionaries.
    match dict_closure_dicts {
        some(dicts) => {
            let lk = match resolved_name { some(rn) => rn, none => name }
            let callable_key = c_resolve_fn(ctx, lk)
            if builtin_value_fact_for_callee(callee_identity).is_some() {
                return gen_c_extern_closure_wrapper(
                    ctx, lk, name, callee_identity, dicts, ty, span)
            }
            // Exact Ring function/ctor (including an extern-forward bridge)
            // wins over the extern registry. This preserves user shadowing
            // such as a Ring `fn print`/`fn Cell` and keeps bridge context on
            // the ordinary Ring wrapper path.
            if ctx.ring_callable_names.contains(callable_key) {
                return gen_c_dict_closure_wrapper(ctx, lk, name, dicts, ty)
            }
            if ctx.extern_callable_names.contains(callable_key) {
                return gen_c_extern_closure_wrapper(
                    ctx, lk, name, callee_identity, dicts, ty, span)
            }
            panic("C codegen: function value '${name}' has provenance but no exact Ring or extern target")
        },
        none => {},
    }
    let lookup_name = match resolved_name {
        some(rn) => rn,
        none => name,
    }
    let boxed = is_boxed_def_c(ctx, def_id)
    let found = match def_id {
        some(id) => match c_exact_value_slot(ctx, name, id) {
            some(slot) => some(c_ref_exact(slot)),
            none => none
        },
        none => {
            match c_name_only_value(ctx, lookup_name) {
                some(slot) => some(c_ref_name_only(slot)),
                none => match c_name_only_value(ctx, name) {
                    some(slot) => some(c_ref_name_only(slot)),
                    none => none
                }
            }
        }
    }
    match found {
        some(reference) => {
            let cv = c_ref_c_name(reference)
            let t = fresh_tmp(ctx)
            if boxed {
                // B-091 mut-cell: the variable holds the CELL pointer.
                c_emit(ctx, "${t} = *(void**)${cv};")
            } else {
                c_emit(ctx, "${t} = ${cv};")
            }
            t
        },
        none => {
            // Module direct-callable values must carry exact checker
            // provenance, including the explicit empty marker for zero-bound
            // functions. Never guess from FnType/name at the backend.
            match ty {
                Type::FnType { .. } => {
                    panic("C codegen: function value '${name}' is missing materialization provenance")
                },
                _ => {},
            }
            // Module-level const getter. Step 8: module-
            // aware resolution chain — resolved key → bare name → resolved
            // name → bare lookup_name → precise lookup (gen_ident parity).
            let fn_info = match c_lookup_key(ctx, c_resolve_fn(ctx, lookup_name)) {
                some(r) => some(r),
                none => match c_lookup_key(ctx, c_mangle_fn(name)) {
                    some(r) => some(r),
                    none => match c_lookup_key(ctx, c_resolve_fn(ctx, name)) {
                        some(r) => some(r),
                        none => match c_lookup_key(ctx, c_mangle_fn(lookup_name)) {
                            some(r) => some(r),
                            none => match c_find_fn_precise(ctx, name) {
                                some(r) => some(r),
                                none => c_find_fn_precise(ctx, lookup_name),
                            },
                        },
                    },
                },
            }
            match fn_info {
                some(lookup) => {
                    let value_arity = if lookup.fi.takes_effect_ctx {
                        lookup.fi.total_params - 1
                    } else {
                        lookup.fi.total_params
                    }
                    if value_arity == 0 {
                        // Zero-arg const getter — call it.
                        let t = fresh_tmp(ctx)
                        if lookup.fi.takes_effect_ctx {
                            rt_use(ctx, "ring_effect_ctx_empty", 0)
                            c_emit(ctx,
                                "${t} = ${lookup.fi.c_name}(ring_effect_ctx_empty());")
                        } else {
                            c_emit(ctx, "${t} = ${lookup.fi.c_name}();")
                        }
                        t
                    } else {
                        // Non-FnType-annotated fn reference (checker gap) —
                        // raw pointer, matching call_zero_arg_or_return's
                        // bare fn_val return on the LLVM side.
                        let t = fresh_tmp(ctx)
                        c_emit(ctx, "${t} = (void*)${lookup.fi.c_name};")
                        t
                    }
                },
                none => panic("C codegen: undefined variable '${name}' (resolved: '${lookup_name}')"),
            }
        },
    }
}

// Extern/builtin function values use a separate uniform-closure thunk.  Their
// direct ABI is intentionally not the Ring fn(args, dicts, ctx) ABI:
// runtime externs need exact symbol mapping and scalar print coercion, while
// LLVM-C externs (in the LLVM backend twin below) need C-ABI marshalling.
// Build a typed synthetic direct Call in the thunk so the ordinary call
// lowering remains the single source of truth for all of those conversions.
fn gen_c_extern_closure_wrapper(
    mut ctx: CCtx, lookup_name: Str, name: Str,
    callee_identity: CalleeRef?, dict_refs: List<DictRef>,
    ty: Type, span: Span
) -> Str {
    if dict_refs.len() != 0 {
        panic("C codegen: extern closure wrapper for '${name}' received ${dict_refs.len()} dicts")
    }
    let (param_types, return_type, fn_effects) = match ty {
        Type::FnType { params, return_type, effects } => (params, return_type, effects),
        _ => panic("C codegen: extern closure wrapper for non-function '${name}'"),
    }

    let wn = ctx.dictwrap_counter
    ctx.dictwrap_counter = wn + 1
    let thunk_name = "ring_externwrap_${wn}"
    let mut sig_parts: List<Str> = ["void* env"]
    for i in 0..param_types.len() { sig_parts.push("void* p${i}") }
    sig_parts.push("EffectCtx* effect_ctx")
    let params_str = sig_parts.join(", ")
    ctx.fn_protos.push("void* ${thunk_name}(${params_str});")

    let saved = c_push_fn(ctx, thunk_name)
    let mut synthetic_args: List<HExpr> = []
    let mut i = 0
    for param_ty in param_types {
        let param_name = "__ring_extern_arg_${wn}_${i}"
        c_register_name_only_value(ctx, param_name, "p${i}")
        synthetic_args.push(HExpr::Ident {
            name: param_name, resolved_name: none, def_id: none,
            source_slot: none, callee_identity: none,
            dict_closure_dicts: none, callable_instantiation: none, ty: param_ty,
            effects: EMPTY_ROW, span: span
        })
        i = i + 1
    }
    let synthetic_callee = HExpr::Ident {
        name: name, resolved_name: some(lookup_name), def_id: none,
        source_slot: none, callee_identity: none,
        dict_closure_dicts: none, callable_instantiation: none,
        ty: ty, effects: EMPTY_ROW, span: span
    }
    let extern_key = c_resolve_fn(ctx, lookup_name)
    let system_host = if ctx.extern_callable_names.contains(extern_key) {
        match callee_identity {
        some(identity) => {
            if !callee_ref_is_named(identity) {
                panic("C codegen: extern wrapper callee is not named")
            }
            let executable = make_named_executable_ref(
                callee_ref_named_symbol(identity))
            let abi_name = match ctx.extern_abi_names.get(extern_key) {
                some(value) => value,
                none => panic("C codegen: extern wrapper HDecl is absent")
            }
            host_import_fact_for_declaration(
                executable, abi_name, ty).map(fn(fact) {
                    host_import_fact_host(fact)
                })
        },
        none => none
        }
    } else { none }
    let result = if c_compiler_extern_forwards_ctx(callee_identity) {
        let mut raw_args: List<Str> = []
        for index in 0..param_types.len() {
            raw_args.push("p${index}")
        }
        gen_c_direct_call(ctx, lookup_name, raw_args, [],
            "effect_ctx", callee_identity)
    } else {
        gen_c_expr(ctx, HExpr::Call {
            callee: synthetic_callee, args: synthetic_args, type_args: [],
            effect_instantiation: none,
            resolved_dicts: [], effect_ctx: make_empty_effect_ctx_source(),
            callee_ref: callee_identity, method_ref: none,
            system_host: system_host,
            ty: return_type,
            effects: fn_effects, span: span
        })
    }
    c_emit(ctx, "return ${result};")
    c_pop_fn(ctx, thunk_name, params_str, saved)

    // Zero-capture env still carries the count header required by typeid 15.
    rt_use(ctx, "ring_alloc", 2)
    let env = fresh_tmp(ctx)
    c_emit(ctx, "${env} = ring_alloc((int64_t)sizeof(int64_t), 15);")
    c_emit(ctx, "*(int64_t*)${env} = 0;")
    let cls = fresh_tmp(ctx)
    c_emit(ctx, "${cls} = ring_alloc((int64_t)(2 * sizeof(void*)), 7);")
    c_emit(ctx, "((void**)${cls})[0] = (void*)${thunk_name};")
    c_emit(ctx, "((void**)${cls})[1] = ${env};")
    cls
}

// Wrap fn(args, dicts, ctx) as {thunk, env}. Only dictionaries are captured;
// EffectCtx always arrives from the invocation site and is forwarded last.
fn gen_c_dict_closure_wrapper(mut ctx: CCtx, lookup_name: Str, name: Str, dict_refs: List<DictRef>, ty: Type) -> Str {
    // Resolve the real function (step 8: module-aware chain, LLVM parity).
    let mangled = c_resolve_fn(ctx, lookup_name)
    let found = match c_find_function_in_ctx(ctx, mangled, name) {
        some(r) => r,
        none => panic("C codegen: dict-closure wrapper: function '${name}' not found"),
    }
    let fn_key = found.key
    let fi = found.fi

    // Param count of the FUNCTION VALUE (without dictionaries/context).
    let param_count = match ty {
        Type::FnType { params, .. } => params.len(),
        _ => 0,
    }

    let expected_dict_count = match ctx.fn_trait_bounds.get(fn_key) {
        some(bounds) => bounds.len(),
        none => 0,
    }
    if dict_refs.len() != expected_dict_count {
        panic("C codegen: dict-closure wrapper for '${name}' expected ${expected_dict_count} checker-resolved dicts, got ${dict_refs.len()}")
    }

    // Resolve the checker-selected dicts at this site.  A raw Wrapped value is
    // defensive only (dict_lower normally makes it an HIR-visible local): it
    // is freshly owned, so release that construction ref after the env dup.
    let mut dict_vals: List<Str> = []
    let mut owned_dict_vals: List<Str> = []
    for dr in dict_refs {
        let reference = c_resolve_dict_ref(ctx, dr)
        let value = c_ref_c_name(reference)
        dict_vals.push(value)
        if !dict_ref_is_simple_physical(dr) &&
           !dict_ref_is_static_physical(dr) {
            owned_dict_vals.push(value)
        }
    }

    let captured_count = dict_vals.len()
    if fi.total_params != param_count + captured_count + 1 {
        panic("C codegen: dict-closure wrapper ABI arity differs")
    }

    // Thunk: fn(env, p0..pN-1) -> forwards (p0.., env slots 1..captured).
    // Pure text (no temps needed) — env slots read inline.
    let wn = ctx.dictwrap_counter
    ctx.dictwrap_counter = wn + 1
    let thunk_name = "ring_dictwrap_${wn}"
    let mut sig_parts: List<Str> = ["void* env"]
    let mut fwd_args: List<Str> = []
    for i in 0..param_count {
        sig_parts.push("void* p${i}")
        fwd_args.push("p${i}")
    }
    for i in 0..captured_count {
        fwd_args.push("((void**)env)[${i + 1}]")
    }
    sig_parts.push("EffectCtx* effect_ctx")
    fwd_args.push("effect_ctx")
    ctx.fn_protos.push("void* ${thunk_name}(${sig_parts.join(", ")});")
    let mut def: List<Str> = []
    def.push("void* ${thunk_name}(${sig_parts.join(", ")}) {")
    def.push("    return ${fi.c_name}(${fwd_args.join(", ")});")
    def.push("}")
    ctx.fn_defs.push(def.join("\n"))

    // Env { i64 count(=dict_count), dicts... } + closure pair.
    rt_use(ctx, "ring_alloc", 2)
    let env = fresh_tmp(ctx)
    c_emit(ctx, "${env} = ring_alloc((int64_t)(sizeof(int64_t) + ${captured_count} * sizeof(void*)), 15);")
    c_emit(ctx, "*(int64_t*)${env} = ${dict_vals.len()};")
    let mut slot_idx = 0
    for dv in dict_vals {
        rt_use(ctx, "ring_dup", 1)
        c_emit(ctx, "ring_dup(${dv});")
        c_emit(ctx, "((void**)${env})[${slot_idx + 1}] = ${dv};")
        slot_idx = slot_idx + 1
    }
    for owned in owned_dict_vals {
        rt_use(ctx, "ring_drop", 1)
        c_emit(ctx, "ring_drop(${owned});")
    }
    let cls = fresh_tmp(ctx)
    c_emit(ctx, "${cls} = ring_alloc((int64_t)(2 * sizeof(void*)), 7);")
    c_emit(ctx, "((void**)${cls})[0] = (void*)${thunk_name};")
    c_emit(ctx, "((void**)${cls})[1] = ${env};")
    cls
}

// ============================================================
// Binary operations
// ============================================================

fn gen_c_binop(mut ctx: CCtx, op: BinOp, left: HExpr, right: HExpr, eq_dispatch: TraitDispatch?, ord_dispatch: TraitDispatch?, result_ty: Type) -> Str {
    let op_type = hexpr_type(left)

    // B-104 D7: `&&`/`||` are rewritten to IfExpr by andor_lower before codegen.
    match op {
        BinOp::And => panic("C codegen: BinOp::And must be lowered by andor_lower"),
        BinOp::Or => panic("C codegen: BinOp::Or must be lowered by andor_lower"),
        _ => {},
    }

    // Trait-dispatched comparisons (Eq / Ord) — MUST take precedence over the
    // primitive fallback (a generic `x == item` miscompiled as integer compare
    // silently fails for heap Strs / structs, LLVM parity).
    let is_eq_op = match op { BinOp::Eq => true, BinOp::Neq => true, _ => false }
    let is_ord_op = match op {
        BinOp::Lt => true, BinOp::Lte => true, BinOp::Gt => true, BinOp::Gte => true, _ => false,
    }
    if is_eq_op {
        match eq_dispatch {
            some(d) => match d {
                TraitDispatch::Builtin => {},
                _ => { return gen_c_eq_dispatch(ctx, op, left, right, d) },
            },
            none => {},
        }
    }
    if is_ord_op {
        match ord_dispatch {
            some(d) => match d {
                TraitDispatch::Builtin => {},
                _ => { return gen_c_ord_dispatch(ctx, op, left, right, d) },
            },
            none => {},
        }
    }

    let lhs = gen_c_expr(ctx, left)
    let rhs = gen_c_expr(ctx, right)

    if is_int_type(op_type) {
        gen_c_int_binop(ctx, op, lhs, rhs)
    } else if is_float_type(op_type) {
        gen_c_float_binop(ctx, op, lhs, rhs)
    } else if is_str_type(op_type) {
        gen_c_str_binop(ctx, op, lhs, rhs)
    } else if is_bool_type(op_type) {
        gen_c_bool_binop(ctx, op, lhs, rhs)
    } else {
        // Fallback: integer ops (LLVM backend parity).
        gen_c_int_binop(ctx, op, lhs, rhs)
    }
}

// B-148 port: zero-divisor guard before sdiv/srem (UB on both backends).
fn emit_c_divzero_guard(mut ctx: CCtx, rhs: Str) {
    let g = c_interned_cstr(ctx, "integer division by zero")
    rt_use(ctx, "ring_panic", 1)
    rt_use(ctx, "ring_str_from_cstr", 1)
    c_emit(ctx, "if (RING_UNTAG(${rhs}) == 0) { ring_panic(ring_str_from_cstr(${g})); }")
}

fn gen_c_int_binop(mut ctx: CCtx, op: BinOp, lhs: Str, rhs: Str) -> Str {
    let t = fresh_tmp(ctx)
    // RING_IADD/… wrap in unsigned space — LLVM add/sub/mul (no nsw) parity,
    // avoiding C signed-overflow UB.
    match op {
        BinOp::Add => c_emit(ctx, "${t} = RING_INT(RING_IADD(RING_UNTAG(${lhs}), RING_UNTAG(${rhs})));"),
        BinOp::Sub => c_emit(ctx, "${t} = RING_INT(RING_ISUB(RING_UNTAG(${lhs}), RING_UNTAG(${rhs})));"),
        BinOp::Mul => c_emit(ctx, "${t} = RING_INT(RING_IMUL(RING_UNTAG(${lhs}), RING_UNTAG(${rhs})));"),
        BinOp::Div => {
            emit_c_divzero_guard(ctx, rhs)
            c_emit(ctx, "${t} = RING_INT(RING_UNTAG(${lhs}) / RING_UNTAG(${rhs}));")
        },
        BinOp::Mod => {
            emit_c_divzero_guard(ctx, rhs)
            c_emit(ctx, "${t} = RING_INT(RING_UNTAG(${lhs}) % RING_UNTAG(${rhs}));")
        },
        BinOp::Eq => c_emit(ctx, "${t} = RING_BOOL(RING_UNTAG(${lhs}) == RING_UNTAG(${rhs}));"),
        BinOp::Neq => c_emit(ctx, "${t} = RING_BOOL(RING_UNTAG(${lhs}) != RING_UNTAG(${rhs}));"),
        BinOp::Lt => c_emit(ctx, "${t} = RING_BOOL(RING_UNTAG(${lhs}) < RING_UNTAG(${rhs}));"),
        BinOp::Lte => c_emit(ctx, "${t} = RING_BOOL(RING_UNTAG(${lhs}) <= RING_UNTAG(${rhs}));"),
        BinOp::Gt => c_emit(ctx, "${t} = RING_BOOL(RING_UNTAG(${lhs}) > RING_UNTAG(${rhs}));"),
        BinOp::Gte => c_emit(ctx, "${t} = RING_BOOL(RING_UNTAG(${lhs}) >= RING_UNTAG(${rhs}));"),
        BinOp::And => panic("C codegen: BinOp::And lowered by andor_lower — unreachable"),
        BinOp::Or => panic("C codegen: BinOp::Or lowered by andor_lower — unreachable"),
    }
    t
}

fn gen_c_float_binop(mut ctx: CCtx, op: BinOp, lhs: Str, rhs: Str) -> Str {
    rt_use(ctx, "ring_unbox_float", 1)
    // Unbox once into double temps (evaluation order parity with LLVM).
    let ld = fresh_dbl(ctx)
    let rd = fresh_dbl(ctx)
    c_emit(ctx, "${ld} = ring_unbox_float(${lhs});")
    c_emit(ctx, "${rd} = ring_unbox_float(${rhs});")
    let t = fresh_tmp(ctx)
    match op {
        BinOp::Add => { rt_use(ctx, "ring_box_float", 1); c_emit(ctx, "${t} = ring_box_float(${ld} + ${rd});") },
        BinOp::Sub => { rt_use(ctx, "ring_box_float", 1); c_emit(ctx, "${t} = ring_box_float(${ld} - ${rd});") },
        BinOp::Mul => { rt_use(ctx, "ring_box_float", 1); c_emit(ctx, "${t} = ring_box_float(${ld} * ${rd});") },
        BinOp::Div => { rt_use(ctx, "ring_box_float", 1); c_emit(ctx, "${t} = ring_box_float(${ld} / ${rd});") },
        BinOp::Mod => { rt_use(ctx, "ring_box_float", 1); c_emit(ctx, "${t} = ring_box_float(fmod(${ld}, ${rd}));") },
        BinOp::Eq => c_emit(ctx, "${t} = RING_BOOL(${ld} == ${rd});"),
        // LLVM ONE (ordered-not-equal): NaN operands compare false.
        // C `!=` is UNordered-true, so use (a<b || a>b).
        BinOp::Neq => c_emit(ctx, "${t} = RING_BOOL(${ld} < ${rd} || ${ld} > ${rd});"),
        BinOp::Lt => c_emit(ctx, "${t} = RING_BOOL(${ld} < ${rd});"),
        BinOp::Lte => c_emit(ctx, "${t} = RING_BOOL(${ld} <= ${rd});"),
        BinOp::Gt => c_emit(ctx, "${t} = RING_BOOL(${ld} > ${rd});"),
        BinOp::Gte => c_emit(ctx, "${t} = RING_BOOL(${ld} >= ${rd});"),
        _ => panic("C codegen: unsupported float binop"),
    }
    t
}

fn gen_c_str_binop(mut ctx: CCtx, op: BinOp, lhs: Str, rhs: Str) -> Str {
    let t = fresh_tmp(ctx)
    match op {
        BinOp::Eq => {
            rt_use(ctx, "ring_str_eq", 2)
            c_emit(ctx, "${t} = RING_BOOL(ring_str_eq(${lhs}, ${rhs}));")
        },
        BinOp::Neq => {
            rt_use(ctx, "ring_str_eq", 2)
            c_emit(ctx, "${t} = RING_BOOL(1 - ring_str_eq(${lhs}, ${rhs}));")
        },
        BinOp::Lt => {
            rt_use(ctx, "ring_str_lt", 2)
            c_emit(ctx, "${t} = RING_BOOL(ring_str_lt(${lhs}, ${rhs}));")
        },
        BinOp::Gt => {
            rt_use(ctx, "ring_str_lt", 2)
            c_emit(ctx, "${t} = RING_BOOL(ring_str_lt(${rhs}, ${lhs}));")
        },
        BinOp::Lte => {
            // a <= b  ≡  !(b < a)
            rt_use(ctx, "ring_str_lt", 2)
            c_emit(ctx, "${t} = RING_BOOL(1 - ring_str_lt(${rhs}, ${lhs}));")
        },
        BinOp::Gte => {
            // a >= b  ≡  !(a < b)
            rt_use(ctx, "ring_str_lt", 2)
            c_emit(ctx, "${t} = RING_BOOL(1 - ring_str_lt(${lhs}, ${rhs}));")
        },
        _ => panic("C codegen: unsupported str binop"),
    }
    t
}

fn gen_c_bool_binop(mut ctx: CCtx, op: BinOp, lhs: Str, rhs: Str) -> Str {
    let t = fresh_tmp(ctx)
    match op {
        BinOp::Eq => c_emit(ctx, "${t} = RING_BOOL(RING_UNTAG(${lhs}) == RING_UNTAG(${rhs}));"),
        BinOp::Neq => c_emit(ctx, "${t} = RING_BOOL(RING_UNTAG(${lhs}) != RING_UNTAG(${rhs}));"),
        _ => panic("C codegen: unsupported bool binop"),
    }
    t
}

// ============================================================
// Unary operations
// ============================================================

fn gen_c_unaryop(mut ctx: CCtx, op: UnaryOp, operand: HExpr, ty: Type) -> Str {
    let v = gen_c_expr(ctx, operand)
    let t = fresh_tmp(ctx)
    match op {
        UnaryOp::Neg => {
            if is_int_type(ty) {
                c_emit(ctx, "${t} = RING_INT(RING_INEG(RING_UNTAG(${v})));")
            } else {
                rt_use(ctx, "ring_unbox_float", 1)
                rt_use(ctx, "ring_box_float", 1)
                c_emit(ctx, "${t} = ring_box_float(0.0 - ring_unbox_float(${v}));")
            }
        },
        UnaryOp::Not => {
            c_emit(ctx, "${t} = RING_BOOL(1 - RING_UNTAG(${v}));")
        },
    }
    t
}

// ============================================================
// Calls
// ============================================================

struct CNameOnlyMatch {
    canonical_key: Str,
    slot: CNameOnlySlotRef
}

// Reuse the identity layer's stable path/slot encoder so this registry key
// contains the complete opaque SymbolRef: origin module, namespace, payload
// and declaration site. The fixed child component only domains the adapter.
pub fn c_exact_mut_symbol_key(symbol: SymbolRef) -> Str {
    slot_ref_stable_key(make_synthetic_slot_ref(make_path_ref(
        path_owner_for_symbol(symbol), ["c-exact-mut-abi"],
        path_role_synthetic())))
}

// Resolve the actual registered key once.  A resolved/qualified key wins;
// the bare spelling is consulted only when it names a distinct explicit
// name-only registration.  Module/global registries are deliberately absent.
fn c_match_name_only_slot(
    ctx: CCtx, resolved_key: Str, bare_key: Str
) -> CNameOnlyMatch? {
    match c_name_only_value(ctx, resolved_key) {
        some(slot) => some(CNameOnlyMatch {
            canonical_key: resolved_key, slot: slot
        }),
        none => {
            if bare_key == resolved_key { return none }
            match c_name_only_value(ctx, bare_key) {
                some(slot) => some(CNameOnlyMatch {
                    canonical_key: bare_key, slot: slot
                }),
                none => none
            }
        }
    }
}

// Calls consume the exact executable's recorded CELL-parameter ABI.  An
// exact CalleeRef never falls back to a leaf/name-derived entry.
fn c_lookup_call_mut_flags(
    ctx: CCtx, callee: HExpr, callee_ref: CalleeRef?,
    method_ref: MethodCallRef?
) -> List<Bool>? {
    match method_ref {
        some(exact) => if method_call_ref_is_concrete(exact) {
            let flags = match ctx.fn_mut_params.get(impl_method_ref_stable_key(
                    method_call_ref_impl(exact))) {
                some(values) => values,
                none => return none
            }
            // Method arguments exclude the leading receiver/self slot.
            let mut shifted: List<Bool> = []
            let mut index = 1
            while index < flags.len() {
                shifted.push(flags.get(index).unwrap())
                index = index + 1
            }
            return some(shifted)
        },
        none => {}
    }
    match callee_ref {
        some(exact) => {
            if callee_ref_is_named(exact) {
                return ctx.fn_mut_params.get(c_exact_mut_symbol_key(
                    callee_ref_named_symbol(exact)))
            }
            return none
        },
        none => {}
    }
    match callee {
        HExpr::Ident {
            name, resolved_name, def_id, dict_closure_dicts, ..
        } => {
            let call_name = match resolved_name {
                some(rn) => rn,
                none => name,
            }
            // Local closures carry their own callable ABI. They must not
            // inherit mut-parameter metadata from a same-spelled module fn.
            match def_id {
                some(id) => match c_exact_value_slot(ctx, name, id) {
                    some(_) => { return none },
                    none => match dict_closure_dicts {
                        // Marked declaration/constructor: module mut metadata
                        // is authoritative after the exact-local miss.
                        some(_) => {},
                        // Unmarked exact local: gen_c_call will fail loud.
                        none => { return none }
                    }
                },
                none => match c_match_name_only_slot(ctx, call_name, name) {
                    some(_) => { return none },
                    none => {}
                }
            }
            // Project metadata uses the same semantic key as the function
            // registry.  This is essential for aliases and for two modules
            // that export the same bare function name.
            let resolved_key = c_resolve_fn(ctx, call_name)
            match ctx.fn_mut_params.get(resolved_key) {
                some(flags) => some(flags),
                none => match ctx.fn_mut_params.get(call_name) {
                    some(flags) => some(flags),
                    none => ctx.fn_mut_params.get(name),
                },
            }
        },
        HExpr::FieldAccess { .. } => none,
        _ => none,
    }
}

fn gen_c_mut_arg(mut ctx: CCtx, arg: HExpr) -> Str {
    match arg {
        HExpr::Ident { name, resolved_name, def_id, .. } => {
            if is_boxed_def_c(ctx, def_id) {
                // Already a shared cell: pass the cell pointer itself.
                let lookup_name = match resolved_name {
                    some(rn) => rn,
                    none => name,
                }
                let found = match def_id {
                    some(id) => c_exact_value_slot(ctx, name, id),
                    none => panic(
                        "C codegen: boxed local '${name}' has no DefId")
                }
                match found {
                    some(slot) => {
                        let cv = c_exact_slot_c_name(slot)
                        let t = fresh_tmp(ctx)
                        c_emit(ctx, "${t} = ${cv};")
                        t
                    },
                    none => {
                        let v = gen_c_expr(ctx, arg)
                        gen_c_cell_alloc(ctx, v)
                    },
                }
            } else {
                let v = gen_c_expr(ctx, arg)
                gen_c_cell_alloc(ctx, v)
            }
        },
        _ => {
            let v = gen_c_expr(ctx, arg)
            gen_c_cell_alloc(ctx, v)
        },
    }
}

// B-091 mut-cell: single-slot heap cell { void* value }, typeid 14 (CELL).
pub fn gen_c_cell_alloc(mut ctx: CCtx, init_val: Str) -> Str {
    rt_use(ctx, "ring_alloc", 2)
    let t = fresh_tmp(ctx)
    c_emit(ctx, "${t} = ring_alloc((int64_t)sizeof(void*), 14);")
    c_emit(ctx, "*(void**)${t} = ${init_val};")
    t
}

// ============================================================
// Trait dict machinery (step 5) — ports of resolve_dict_ref /
// resolve_static_dict_by_name / get_or_create_static_dict_getter /
// build_wrapped_dict / emit_wrapped_method_thunk.
//
// Value layouts (shared with the LLVM backend + ring_runtime.cpp):
//   dict    { int64_t method_count, void* m0, ... }   typeid 16/17
//   closure { void* fn_ptr, void* env_ptr }           typeid 7
//   env     { int64_t count, void* slot0, ... }       typeid 15
// ============================================================

pub fn c_resolve_dict_ref(mut ctx: CCtx, dr: DictRef) -> CTypedRef {
    let exact = dict_ref_exact(dr)
    if dict_ref_is_simple_physical(dr) {
        return c_resolve_simple_dict_name(ctx, dict_ref_simple_name(dr))
    }
    if dict_ref_is_static_physical(dr) {
        let key = c_static_dict_physical_key(exact)
        return c_ref_static(resolve_c_static_dict(ctx, exact), key)
    }
    // Post-dict_lower this survives in BinOp dispatch and dynamic derived
    // FieldAction evidence.
    let value = build_c_wrapped_dict(
        ctx, dict_ref_wrapped_physical_inner(dr), exact)
    c_ref_computed(value,
        "wrapped-dict:${c_trait_dict_physical_key(
            dict_ref_wrapped_base(exact))}")
}

fn c_resolve_simple_dict_name(mut ctx: CCtx, name: Str) -> CTypedRef {
    match c_name_only_value(ctx, name) {
        some(slot) => c_ref_name_only(slot),
        none => panic(
            "C codegen: bound dictionary '${name}' has no name-only slot")
    }
}

// Borrow the memoised module singleton for a static dict: emit (once) the
// lazy getter ring_dict_init_<name> and call it.
pub fn resolve_c_static_dict(
    mut ctx: CCtx, exact: ExactDictRef
) -> Str {
    let getter = ensure_c_dict_getter(ctx, exact)
    let t = fresh_tmp(ctx)
    c_emit(ctx, "${t} = ${getter}();")
    t
}

// Emit (once) the memoised singleton getter for a static dict.  Getter body
// decides by REGISTRY, not decl order (dict_build_fns is fully populated in
// the forward pass — impl dicts + derived dicts — so a use site earlier in
// decl order than its impl still binds the real dict; the LLVM backend's
// lazy fallback is decl-order-sensitive there):
//   * a registered build fn (impl / derived trait dict) → call it;
//   * an exact wrapped INSTANCE → recursively resolve its ExactDictRef tree
//     and build_wrapped_dict with the DICT_STATIC typeid;
//   * otherwise → runtime builtin dict (ring_get_builtin_dict).
pub fn ensure_c_dict_getter(
    mut ctx: CCtx, exact: ExactDictRef
) -> Str {
    let key = c_static_dict_physical_key(exact)
    let getter_name = c_static_dict_getter_symbol(exact)
    match ctx.dict_getters.get(key) {
        some(existing) => {
            if !dict_ref_same(existing, exact) {
                panic("C codegen: one static dict key has multiple exact identities")
            }
            return getter_name
        },
        none => ctx.dict_getters.insert(key, exact)
    }
    let gvar = c_static_dict_global_symbol(exact)
    ctx.globals.push("static void* ${gvar} = 0;")
    ctx.fn_protos.push("void* ${getter_name}(void);")

    let saved = c_push_fn(ctx, getter_name)
    c_emit(ctx, "if (${gvar} == 0) {")
    ctx.indent = ctx.indent + 1
    if dict_ref_is_wrapped(exact) {
        let v = build_c_wrapped_static_dict_typed(ctx, exact, 16)
        c_emit(ctx, "${gvar} = ${v};")
    } else if dict_ref_is_static(exact) {
        let owner = dict_ref_static(exact)
        let owner_key = c_trait_dict_physical_key(owner)
        match ctx.dict_build_owners.get(owner_key) {
            some(registered) => {
                if !impl_owner_ref_same(registered, owner) ||
                   !ctx.dict_build_fns.contains(owner_key) {
                    panic("C codegen: ordinary dict build owner/index differs")
                }
                c_emit(ctx,
                    "${gvar} = ${c_trait_dict_build_symbol(owner)}();")
            },
            none => {
                let provider_kind = impl_provider_ref_kind(
                    impl_owner_ref_provider(owner))
                if !impl_provider_kind_same(
                        provider_kind, impl_provider_kind_builtin()) {
                    panic("C codegen: exact ordinary dict has no build owner")
                }
                // Compiler-provided primitive dictionaries are materialized by
                // the runtime ABI, after exact provider classification.
                rt_use(ctx, "ring_str_from_cstr", 1)
                rt_use(ctx, "ring_get_builtin_dict", 1)
                let abi_name = c_builtin_trait_dict_abi_name(owner)
                let g = c_global_cstr(ctx, abi_name)
                let s = fresh_tmp(ctx)
                c_emit(ctx, "${s} = ring_str_from_cstr(${g});")
                c_emit(ctx, "${gvar} = ring_get_builtin_dict(${s});")
            }
        }
    } else {
        panic("C codegen: static getter lacks exact static/wrapped identity")
    }
    ctx.indent = ctx.indent - 1
    c_emit(ctx, "}")
    c_emit(ctx, "return ${gvar};")
    c_pop_fn(ctx, getter_name, "void", saved)
    getter_name
}

// #B-087 gap 2 port (build_wrapped_dict): a wrapper trait dict for a
// parameterized type whose impl methods take the inner type-param dicts as
// trailing params.  Each method slot is a {thunk, env} closure whose env
// captures only inner dicts; invocation supplies EffectCtx last.
pub fn build_c_wrapped_dict(
    mut ctx: CCtx, inner_dicts: List<DictRef>, exact: ExactDictRef
) -> Str {
    build_c_wrapped_dict_typed(ctx, inner_dicts, exact, 17)
}

pub fn build_c_wrapped_dict_typed(
    mut ctx: CCtx, inner_dicts: List<DictRef>, exact: ExactDictRef,
    dict_tid: Int
) -> Str {
    if !dict_ref_is_wrapped(exact) {
        panic("C codegen: wrapped dictionary lacks exact wrapped identity")
    }
    let exact_inner = dict_ref_wrapped_inner(exact)
    if exact_inner.len() != inner_dicts.len() {
        panic("C codegen: wrapped dictionary exact/physical arity differs")
    }
    // Resolve the inner dicts at this site.
    let mut inner_vals: List<Str> = []
    // A surviving Wrapped child is freshly owned.  The parent wrapper envs
    // take their own refs below, so release these construction temporaries
    // once every method slot has captured them.
    let mut owned_inner_vals: List<Str> = []
    let mut inner_index = 0
    for d in inner_dicts {
        if !dict_ref_same(
                dict_ref_exact(d), exact_inner.get(inner_index).unwrap()) {
            panic("C codegen: wrapped dictionary child identity differs")
        }
        let reference = c_resolve_dict_ref(ctx, d)
        let value = c_ref_c_name(reference)
        inner_vals.push(value)
        if !dict_ref_is_simple_physical(d) &&
           !dict_ref_is_static_physical(d) {
            owned_inner_vals.push(value)
        }
        inner_index = inner_index + 1
    }

    build_c_wrapped_dict_values(
        ctx, dict_ref_wrapped_base(exact),
        inner_vals, owned_inner_vals, dict_tid)
}

fn build_c_wrapped_static_dict_typed(
    mut ctx: CCtx, exact: ExactDictRef, dict_tid: Int
) -> Str {
    if !dict_ref_is_wrapped(exact) {
        panic("C codegen: static wrapped dictionary lost exact identity")
    }
    let exact_inner = dict_ref_wrapped_inner(exact)
    if exact_inner.len() == 0 {
        panic("C codegen: exact wrapped singleton has no children")
    }
    let mut inner_vals: List<Str> = []
    for child in exact_inner {
        if !dict_ref_is_static(child) && !dict_ref_is_wrapped(child) {
            panic("C codegen: fully-static wrapper contains dynamic evidence")
        }
        inner_vals.push(resolve_c_static_dict(ctx, child))
    }
    build_c_wrapped_dict_values(
        ctx, dict_ref_wrapped_base(exact),
        inner_vals, [], dict_tid)
}

fn build_c_wrapped_dict_values(
    mut ctx: CCtx, owner: ImplOwnerRef,
    inner_vals: List<Str>, owned_inner_vals: List<Str>, dict_tid: Int
) -> Str {
    let method_count = c_exact_method_count_for_owner(ctx, owner)
    let inner_count = inner_vals.len()

    rt_use(ctx, "ring_alloc", 2)
    let dict = fresh_tmp(ctx)
    c_emit(ctx, "${dict} = ring_alloc((int64_t)(sizeof(int64_t) + ${method_count} * sizeof(void*)), ${dict_tid});")
    c_emit(ctx, "*(int64_t*)${dict} = ${method_count};")

    for i in 0..method_count {
        let fi = c_method_info_fn(
            c_exact_method_for_owner_slot(ctx, owner, i))
        let dispatch_arity = fi.total_params - inner_count - 1
        if dispatch_arity < 0 {
            panic("C codegen: wrapped method ABI is smaller than evidence")
        }
        let thunk = ensure_c_wrapped_method_thunk(
            ctx, fi.c_name, dispatch_arity, inner_count)

        let env = fresh_tmp(ctx)
        c_emit(ctx, "${env} = ring_alloc((int64_t)(sizeof(int64_t) + ${inner_count} * sizeof(void*)), 15);")
        c_emit(ctx, "*(int64_t*)${env} = ${inner_count};")
        let mut sj = 0
        for iv in inner_vals {
            rt_use(ctx, "ring_dup", 1)
            c_emit(ctx, "ring_dup(${iv});")
            c_emit(ctx, "((void**)${env})[${sj + 1}] = ${iv};")
            sj = sj + 1
        }
        let cls = fresh_tmp(ctx)
        c_emit(ctx, "${cls} = ring_alloc((int64_t)(2 * sizeof(void*)), 7);")
        c_emit(ctx, "((void**)${cls})[0] = (void*)${thunk};")
        c_emit(ctx, "((void**)${cls})[1] = ${env};")
        c_emit(ctx, "((void**)${dict})[${i + 1}] = ${cls};")
    }

    for owned in owned_inner_vals {
        rt_use(ctx, "ring_drop", 1)
        c_emit(ctx, "ring_drop(${owned});")
    }

    dict
}

// Wrapper thunk calls the direct method as visible args, inner dicts, ctx.
fn ensure_c_wrapped_method_thunk(
    mut ctx: CCtx, method_c_name: Str,
    dispatch_arity: Int, inner_count: Int
) -> Str {
    let thunk_name = "${method_c_name}__wrapthunk"
    if ctx.emitted_fns.contains(thunk_name) {
        return thunk_name
    }
    ctx.emitted_fns.insert(thunk_name)

    let mut sig_parts: List<Str> = ["void* env"]
    let mut fwd_args: List<Str> = []
    for i in 0..dispatch_arity {
        sig_parts.push("void* p${i}")
        fwd_args.push("p${i}")
    }
    for j in 0..inner_count {
        fwd_args.push("((void**)env)[${j + 1}]")
    }
    sig_parts.push("EffectCtx* effect_ctx")
    fwd_args.push("effect_ctx")
    ctx.fn_protos.push("void* ${thunk_name}(${sig_parts.join(", ")});")
    let mut def: List<Str> = []
    def.push("void* ${thunk_name}(${sig_parts.join(", ")}) {")
    def.push("    return ${method_c_name}(${fwd_args.join(", ")});")
    def.push("}")
    ctx.fn_defs.push(def.join("\n"))
    thunk_name
}

// ============================================================
// Lambda (closure) — port of gen_lambda + collect_captures family.
// Env layout { i64 count, ptr cap0, ... } (typeid 15, B-084); the closure
// pair {fn_ptr, env_ptr} is typeid 7.  B-098: every capture is OWNED — the
// env takes its own reference (ring_dup at construction), released by
// drop_closure_env.  B-144: extern-handle captures skip the dup (raw foreign
// pointers outside Ring RC; ring_drop on them is a no-op).
// ============================================================

enum CCaptureProvenance {
    Exact { reference: CTypedRef },
    NameOnly { reference: CTypedRef },
    EffectCtxParent { source: CTypedRef, target: SlotRef }
}

struct CCapture {
    provenance: CCaptureProvenance,
    extern_typed: Bool
}

fn gen_c_lambda(
    mut ctx: CCtx, params: List<HParam>, return_type: Type,
    body: HExpr, ty: Type, effect_ctx: TypedCallableEffectCtx
) -> Str {
    gen_c_closure_impl(
        ctx, params, return_type, body, ty, effect_ctx, none, false)
}

fn gen_c_handler_arm(mut ctx: CCtx, handler: HEffectHandler) -> Str {
    let body = handler.body
    let body_ty = hexpr_type(body)
    gen_c_closure_impl(
        ctx, handler.params, body_ty, body, body_ty, handler.effect_ctx,
        some(handler.parent_ctx), true)
}

fn gen_c_closure_impl(
    mut ctx: CCtx, params: List<HParam>, return_type: Type,
    body: HExpr, ty: Type, effect_ctx: TypedCallableEffectCtx,
    parent_ctx: EffectCtxParentCapture?, internal_handler: Bool
) -> Str {
    let _ = return_type
    let _ = ty
    // Capture collection runs against the ENCLOSING scope (named_values of
    // the function being emitted) — before the nested push.
    let mut captures: List<CCapture> = []
    collect_c_captures(ctx, body, params, captures)
    match parent_ctx {
        some(capture) => {
            let source = c_effect_ctx_ref(
                ctx, effect_ctx_parent_capture_source(capture))
            let target = effect_ctx_slot(
                effect_ctx_parent_capture_target(capture))
            for existing in captures {
                match existing.provenance {
                    CCaptureProvenance::EffectCtxParent {
                        target: existing_target, ..
                    } => if slot_ref_same(existing_target, target) {
                        panic("C codegen: handler parent EffectCtx repeats target")
                    },
                    _ => {}
                }
            }
            captures.push(CCapture {
                provenance: CCaptureProvenance::EffectCtxParent {
                    source: source, target: target
                },
                extern_typed: false
            })
        },
        none => if internal_handler {
            panic("C codegen: internal handler lacks parent EffectCtx")
        }
    }

    let ln = ctx.lambda_counter
    ctx.lambda_counter = ln + 1
    let lambda_name = if internal_handler {
        "ring_c_handler_arm_${ln}"
    } else {
        "ring_c_lambda_${ln}"
    }
    let edge = c_new_closure_edge(ctx, lambda_name)

    // ---- nested emission: the lambda function itself ----
    let saved = c_push_fn(ctx, lambda_name)
    let mut sig_parts: List<Str> = ["void* env"]
    // Extract captures from env (slot i+1; slot 0 is the count).
    for i in 0..captures.len() {
        match captures.get(i) {
            some(cap) => {
                match cap.provenance {
                    CCaptureProvenance::Exact { reference } => {
                        let dest_slot = c_local_def_ref(
                            ctx, c_ref_key(reference), some(c_ref_def_id(reference)))
                        emit_c_capture_extract(ctx, edge, reference,
                            c_ref_exact(dest_slot), i + 1)
                    },
                    CCaptureProvenance::NameOnly { reference } => {
                        let dest_slot = c_local_ref(ctx, c_ref_key(reference))
                        emit_c_capture_extract(ctx, edge, reference,
                            c_ref_name_only(dest_slot), i + 1)
                    },
                    CCaptureProvenance::EffectCtxParent {
                        source, target
                    } => {
                        let dest_slot = c_local_effect_ctx_slot(
                            ctx, target, "__effect_ctx_parent")
                        emit_c_effect_ctx_parent_extract(
                            ctx, edge, source, c_ref_exact(dest_slot), i + 1)
                    }
                }
            },
            none => {},
        }
    }
    // Bind regular params.
    for p in params {
        let pv = c_param_def(ctx, p.name, p.def_id)
        sig_parts.push("void* ${pv}")
    }
    if !internal_handler {
        let ctx_name = c_exact_slot_c_name(c_param_effect_ctx_slot(
            ctx, effect_ctx_slot(
                typed_callable_effect_ctx_binding(effect_ctx)),
            "__effect_ctx"))
        sig_parts.push("EffectCtx* ${ctx_name}")
    }
    let val = gen_c_expr(ctx, body)
    c_emit(ctx, "return ${val};")
    let params_str = sig_parts.join(", ")
    ctx.fn_protos.push("void* ${lambda_name}(${params_str});")
    c_pop_fn(ctx, lambda_name, params_str, saved)

    // ---- construction site: env alloc + capture stores + closure pair ----
    rt_use(ctx, "ring_alloc", 2)
    let env = fresh_tmp(ctx)
    c_emit(ctx, "${env} = ring_alloc((int64_t)(sizeof(int64_t) + ${captures.len()} * sizeof(void*)), 15);")
    c_emit(ctx, "*(int64_t*)${env} = ${captures.len()};")
    let env_ref = c_ref_fresh(env, "closure-env:${lambda_name}")
    for i in 0..captures.len() {
        match captures.get(i) {
            some(cap) => {
                let identity = match cap.provenance {
                    CCaptureProvenance::Exact { reference } => reference,
                    CCaptureProvenance::NameOnly { reference } => reference,
                    CCaptureProvenance::EffectCtxParent { source, .. } =>
                        source
                }
                let cv = c_ref_c_name(identity)
                if !cap.extern_typed {
                    rt_use(ctx, "ring_dup", 1)
                    c_emit(ctx, "ring_dup(${cv});")
                }
                emit_c_capture_store(ctx, edge, identity, env_ref, i + 1)
            },
            none => {},
        }
    }
    let closure_ref = emit_c_closure_construction(
        ctx, edge, env_ref, lambda_name)
    c_ref_c_name(closure_ref)
}

fn c_exact_capture_param_is_bound(def_id: Int, params: List<HParam>) -> Bool {
    for p in params {
        let same = match p.def_id {
            some(param_id) => param_id == def_id,
            none => false
        }
        if same { return true }
    }
    false
}

fn push_c_exact_capture(
    ctx: CCtx, name: Str, def_id: Int, extern_typed: Bool,
    params: List<HParam>, mut captures: List<CCapture>
) {
    if c_exact_capture_param_is_bound(def_id, params) { return }
    match c_exact_value_slot(ctx, name, def_id) {
        some(exact_slot) => {
            for existing in captures {
                match existing.provenance {
                    CCaptureProvenance::Exact { reference } => {
                        if c_ref_def_id(reference) == def_id { return }
                    },
                    CCaptureProvenance::NameOnly { reference: _reference } => {},
                    CCaptureProvenance::EffectCtxParent {
                        source: _source, ..
                    } => {}
                }
            }
            captures.push(CCapture {
                provenance: CCaptureProvenance::Exact {
                    reference: c_ref_exact(exact_slot)
                },
                extern_typed: extern_typed
            })
        },
        none => {
            // Not free in the enclosing frame: it is lambda-local or global.
            // Exact use-time lookup remains fail-closed for a malformed local.
            return
        }
    }
}

fn consider_c_exact_reference(
    ctx: CCtx, name: Str, def_id: Int?, extern_typed: Bool,
    params: List<HParam>, mut captures: List<CCapture>
) {
    match def_id {
        some(id) => push_c_exact_capture(
            ctx, name, id, extern_typed, params, captures),
        // A reference without a DefId is global/direct.  Evidence and backend
        // locals enter through their separate name-only metadata paths.
        none => {}
    }
}

fn consider_c_drop_reference(
    ctx: CCtx, name: Str, def_id: Int, extern_typed: Bool,
    params: List<HParam>, mut captures: List<CCapture>
) {
    push_c_exact_capture(ctx, name, def_id, extern_typed, params, captures)
}

fn push_c_name_only_capture(
    matched: CNameOnlyMatch, extern_typed: Bool,
    mut captures: List<CCapture>
) {
    for existing in captures {
        match existing.provenance {
            CCaptureProvenance::Exact { reference: _reference } => {},
            CCaptureProvenance::EffectCtxParent {
                source: _source, ..
            } => {},
            CCaptureProvenance::NameOnly { reference } => {
                if c_ref_key(reference) == matched.canonical_key { return }
            }
        }
    }
    captures.push(CCapture {
        provenance: CCaptureProvenance::NameOnly {
            reference: c_ref_name_only(matched.slot)
        },
        extern_typed: extern_typed
    })
}

fn consider_c_required_name_only_capture(
    ctx: CCtx, resolved_key: Str, bare_key: Str,
    extern_typed: Bool, mut captures: List<CCapture>
) {
    let matched = match c_match_name_only_slot(ctx, resolved_key, bare_key) {
        some(found) => found,
        // Not free in the enclosing frame: a lambda-local Simple will be
        // registered before its actual use.  c_resolve_dict_ref is the loud
        // authority if no local/outer slot exists at that use point.
        none => return
    }
    push_c_name_only_capture(matched, extern_typed, captures)
}

// A nested handler arm is a closure nested inside the closure currently being
// scanned. Its own operation parameters (and future explicit resume binding)
// are lexical locals, while the enclosing closure's parameters must remain in
// the exclusion set. Copy rather than mutate so sibling arms stay isolated.
fn extend_c_handler_capture_params(
    params: List<HParam>,
    handler_params: List<HParam>,
    resume_binding: HPatternBinding?
) -> List<HParam> {
    let mut extended: List<HParam> = []
    for p in params { extended.push(p) }
    for p in handler_params { extended.push(p) }
    match resume_binding {
        some(binding) => {
            extended.push(HParam {
                name: binding.name, ty: binding.ty,
                def_id: some(binding.def_id), is_mutable: false
            })
        },
        none => {},
    }
    extended
}

// #B-087 gap 3: capture the dict param a trait dispatch routes through.
fn collect_c_dispatch_dict(
    ctx: CCtx, dispatch: TraitDispatch?, params: List<HParam>,
    mut captures: List<CCapture>
) {
    match dispatch {
        some(d) => match d {
            TraitDispatch::Dict { param } => consider_c_required_name_only_capture(
                ctx, param, param, false, captures),
            TraitDispatch::Direct { extra_dicts, .. } => {
                // Direct's base is a module Static dictionary.  Only its
                // explicitly tagged trailing evidence may be dynamic.
                for ed in extra_dicts {
                    collect_c_dictref_names(
                        ctx, ed, params, captures)
                }
            },
            TraitDispatch::Tuple { elements, .. } => {
                for element in elements {
                    collect_c_dispatch_dict(
                        ctx, some(element), params, captures)
                }
            },
            TraitDispatch::Builtin => {},
        },
        none => {},
    }
}

fn collect_c_dictref_names(
    ctx: CCtx, dr: DictRef, params: List<HParam>,
    mut captures: List<CCapture>
) {
    if dict_ref_is_simple_physical(dr) {
        let name = dict_ref_simple_name(dr)
        consider_c_required_name_only_capture(
            ctx, name, name, false, captures)
    } else if !dict_ref_is_static_physical(dr) {
        // Wrapped's base is Static; dynamics live only in tagged inners.
        for inner in dict_ref_wrapped_physical_inner(dr) {
            collect_c_dictref_names(ctx, inner, params, captures)
        }
    }
}

// Collect free variable names referenced in a lambda body (port of
// collect_captures).
fn collect_c_captures(
    ctx: CCtx, expr: HExpr, params: List<HParam>,
    mut captures: List<CCapture>
) {
    match expr {
        HExpr::Ident { name, def_id, dict_closure_dicts, ty, .. } => {
            consider_c_exact_reference(ctx, name, def_id,
                is_extern_handle_type(ty, ctx.extern_types),
                params, captures)
            match dict_closure_dicts {
                some(dicts) => {
                    for d in dicts {
                        collect_c_dictref_names(ctx, d, params, captures)
                    }
                },
                none => {},
            }
        },
        HExpr::BinOp { left, right, eq_dispatch, ord_dispatch, .. } => {
            collect_c_captures(ctx, left, params, captures)
            collect_c_captures(ctx, right, params, captures)
            collect_c_dispatch_dict(ctx, eq_dispatch, params, captures)
            collect_c_dispatch_dict(ctx, ord_dispatch, params, captures)
        },
        HExpr::UnaryOp { operand, .. } => {
            collect_c_captures(ctx, operand, params, captures)
        },
        HExpr::Call { callee, args, resolved_dicts, method_ref, effects, .. } => {
            collect_c_captures(ctx, callee, params, captures)
            for a in args {
                collect_c_captures(ctx, a, params, captures)
            }
            for d in resolved_dicts {
                collect_c_dictref_names(ctx, d, params, captures)
            }
            match method_ref {
                some(exact) => if method_call_ref_is_bound(exact) {
                    collect_c_dictref_names(
                        ctx, method_call_ref_bound_evidence(exact),
                        params, captures)
                },
                none => {}
            }
        },
        HExpr::DictConstruct { inner, .. } => {
            for d in inner {
                collect_c_dictref_names(ctx, d, params, captures)
            }
        },
        HExpr::FieldAccess { receiver, .. } => {
            collect_c_captures(ctx, receiver, params, captures)
        },
        HExpr::Block { stmts, tail, .. } => {
            for s in stmts {
                collect_c_captures_stmt(ctx, s, params, captures)
            }
            match tail {
                some(t) => collect_c_captures(ctx, t, params, captures),
                none => {},
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            collect_c_captures(ctx, condition, params, captures)
            collect_c_captures(ctx, then_branch, params, captures)
            match else_branch {
                some(eb) => collect_c_captures(ctx, eb, params, captures),
                none => {},
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            collect_c_captures(ctx, scrutinee, params, captures)
            for arm in arms {
                match arm.guard {
                    some(g) => collect_c_captures(ctx, g, params, captures),
                    none => {},
                }
                collect_c_captures(ctx, arm.body, params, captures)
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for part in parts {
                match part {
                    HStringInterpPart::Expression(e) =>
                        collect_c_captures(ctx, e, params, captures),
                    _ => {},
                }
            }
        },
        HExpr::StructLit { fields, spread, .. } => {
            for f in fields {
                collect_c_captures(ctx, f.value, params, captures)
            }
            match spread {
                some(sp) => collect_c_captures(ctx, sp, params, captures),
                none => {},
            }
        },
        HExpr::ListLit { elements, .. } => {
            for e in elements {
                collect_c_captures(ctx, e, params, captures)
            }
        },
        HExpr::TupleLit { elements, .. } => {
            for e in elements {
                collect_c_captures(ctx, e, params, captures)
            }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            collect_c_captures(ctx, receiver, params, captures)
            collect_c_captures(ctx, index, params, captures)
        },
        HExpr::Lambda { body: lb, .. } => {
            collect_c_captures(ctx, lb, params, captures)
        },
        HExpr::NamedVariantConstruct { fields: nvc_fields, spread: nvc_spread, .. } => {
            for f in nvc_fields {
                collect_c_captures(ctx, f.value, params, captures)
            }
            match nvc_spread {
                some(sp) => collect_c_captures(ctx, sp, params, captures),
                none => {},
            }
        },
        HExpr::TryCatch { body: tc_body, arms: tc_arms, .. } => {
            collect_c_captures(ctx, tc_body, params, captures)
            for arm in tc_arms {
                match arm.guard {
                    some(g) => collect_c_captures(ctx, g, params, captures),
                    none => {},
                }
                collect_c_captures(ctx, arm.body, params, captures)
            }
        },
        HExpr::HandleExpr { body: he_body, handlers: he_handlers, .. } => {
            collect_c_captures(ctx, he_body, params, captures)
            for h in he_handlers {
                let arm_params = extend_c_handler_capture_params(
                    params, h.params, h.resume_binding)
                collect_c_captures(ctx, h.body, arm_params, captures)
            }
        },
        HExpr::EffectOp { args: eo_args, .. } => {
            for a in eo_args {
                collect_c_captures(ctx, a, params, captures)
            }
        },
        HExpr::Clone { inner, .. } =>
            collect_c_captures(ctx, inner, params, captures),
        HExpr::Take { source, .. } =>
            collect_c_captures(ctx, source, params, captures),
        HExpr::ReturnExpr { value, .. } => match value {
            some(v) => collect_c_captures(ctx, v, params, captures),
            none => {},
        },
        HExpr::UnsafeBlock { body, .. } =>
            collect_c_captures(ctx, body, params, captures),
        _ => {},
    }
}

fn collect_c_captures_stmt(
    ctx: CCtx, stmt: HStmt, params: List<HParam>,
    mut captures: List<CCapture>
) {
    match stmt {
        HStmt::Let { init, .. } => collect_c_captures(ctx, init, params, captures),
        HStmt::Var { init, .. } => collect_c_captures(ctx, init, params, captures),
        HStmt::Assign { target, value, .. } => {
            collect_c_captures(ctx, target, params, captures)
            collect_c_captures(ctx, value, params, captures)
        },
        HStmt::ExprStmt { expr, .. } => collect_c_captures(ctx, expr, params, captures),
        HStmt::Return { value, .. } => match value {
            some(v) => collect_c_captures(ctx, v, params, captures),
            none => {},
        },
        HStmt::While { condition, body, .. } => {
            collect_c_captures(ctx, condition, params, captures)
            collect_c_captures(ctx, body, params, captures)
        },
        HStmt::ForIn { iterable, body, .. } => {
            collect_c_captures(ctx, iterable, params, captures)
            collect_c_captures(ctx, body, params, captures)
        },
        HStmt::LetDestructure { init, .. } => {
            collect_c_captures(ctx, init, params, captures)
        },
        HStmt::IfLet { expr, then_block, else_block, .. } => {
            collect_c_captures(ctx, expr, params, captures)
            collect_c_captures(ctx, then_block, params, captures)
            match else_block {
                some(eb) => collect_c_captures(ctx, eb, params, captures),
                none => {},
            }
        },
        // B-084 #131: Perceus branch-balancing may place an HStmt::Drop for an
        // outer-scope variable inside the lambda body — treat as a use.
        HStmt::Drop { name, def_id, slot, place_target, ty, .. } => {
            if slot_ref_is_source(slot) &&
               slot_ref_source_def_id(slot) != def_id {
                panic("C codegen: Drop SlotRef/DefId relation drifted")
            }
            consider_c_drop_reference(ctx, name, def_id,
                is_extern_handle_type(ty, ctx.extern_types),
                params, captures)
            match place_target {
                some(target) => collect_c_captures(
                    ctx, target, params, captures),
                none => {}
            }
        },
        _ => {},
    }
}

// B-144: names whose Ident use in the body has an extern-handle type — the
// lambda construction skips ring_dup for these captures.  (Set intersection
// with the capture list happens at the use site: extern_typed ∩ captures.)
fn collect_c_extern_typed_names(
    expr: HExpr,
    captures: List<Str>,
    params: List<HParam>,
    externs: Set<Str>,
    mut out: Set<Str>
) {
    match expr {
        HExpr::Ident { name, resolved_name, def_id, ty, .. } => {
            let lookup = match resolved_name { some(rn) => rn, none => name }
            let mut found = false
            for c in captures {
                if c == lookup || c == name { found = true }
            }
            let bound = match def_id {
                some(id) => c_exact_capture_param_is_bound(id, params),
                none => false
            }
            if found
                && bound == false
                && is_extern_handle_type(ty, externs) {
                out.insert(lookup)
            }
        },
        HExpr::BinOp { left, right, .. } => {
            collect_c_extern_typed_names(left, captures, params, externs, out)
            collect_c_extern_typed_names(right, captures, params, externs, out)
        },
        HExpr::UnaryOp { operand, .. } =>
            collect_c_extern_typed_names(operand, captures, params, externs, out),
        HExpr::Call { callee, args, .. } => {
            collect_c_extern_typed_names(callee, captures, params, externs, out)
            for a in args { collect_c_extern_typed_names(a, captures, params, externs, out) }
        },
        HExpr::FieldAccess { receiver, .. } =>
            collect_c_extern_typed_names(receiver, captures, params, externs, out),
        HExpr::Block { stmts, tail, .. } => {
            for s in stmts {
                collect_c_extern_typed_names_stmt(s, captures, params, externs, out)
            }
            match tail {
                some(t) => collect_c_extern_typed_names(t, captures, params, externs, out),
                none => {},
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            collect_c_extern_typed_names(condition, captures, params, externs, out)
            collect_c_extern_typed_names(then_branch, captures, params, externs, out)
            match else_branch {
                some(eb) => collect_c_extern_typed_names(eb, captures, params, externs, out),
                none => {},
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            collect_c_extern_typed_names(scrutinee, captures, params, externs, out)
            for arm in arms {
                match arm.guard {
                    some(g) => collect_c_extern_typed_names(g, captures, params, externs, out),
                    none => {},
                }
                collect_c_extern_typed_names(arm.body, captures, params, externs, out)
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for part in parts {
                match part {
                    HStringInterpPart::Expression(e) =>
                        collect_c_extern_typed_names(e, captures, params, externs, out),
                    _ => {},
                }
            }
        },
        HExpr::StructLit { fields, spread, .. } => {
            for f in fields {
                collect_c_extern_typed_names(f.value, captures, params, externs, out)
            }
            match spread {
                some(sp) => collect_c_extern_typed_names(sp, captures, params, externs, out),
                none => {},
            }
        },
        HExpr::ListLit { elements, .. } => {
            for e in elements {
                collect_c_extern_typed_names(e, captures, params, externs, out)
            }
        },
        HExpr::TupleLit { elements, .. } => {
            for e in elements {
                collect_c_extern_typed_names(e, captures, params, externs, out)
            }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            collect_c_extern_typed_names(receiver, captures, params, externs, out)
            collect_c_extern_typed_names(index, captures, params, externs, out)
        },
        HExpr::Lambda { body: lb, .. } =>
            collect_c_extern_typed_names(lb, captures, params, externs, out),
        HExpr::NamedVariantConstruct { fields: nvc_fields, spread: nvc_spread, .. } => {
            for f in nvc_fields {
                collect_c_extern_typed_names(f.value, captures, params, externs, out)
            }
            match nvc_spread {
                some(sp) => collect_c_extern_typed_names(sp, captures, params, externs, out),
                none => {},
            }
        },
        HExpr::TryCatch { body: tc_body, arms: tc_arms, .. } => {
            collect_c_extern_typed_names(tc_body, captures, params, externs, out)
            for arm in tc_arms {
                match arm.guard {
                    some(g) => collect_c_extern_typed_names(g, captures, params, externs, out),
                    none => {},
                }
                collect_c_extern_typed_names(arm.body, captures, params, externs, out)
            }
        },
        HExpr::HandleExpr { body: he_body, handlers: he_handlers, .. } => {
            collect_c_extern_typed_names(he_body, captures, params, externs, out)
            for h in he_handlers {
                let arm_params = extend_c_handler_capture_params(
                    params, h.params, h.resume_binding)
                collect_c_extern_typed_names(h.body, captures, arm_params, externs, out)
            }
        },
        HExpr::EffectOp { args: eo_args, .. } => {
            for a in eo_args {
                collect_c_extern_typed_names(a, captures, params, externs, out)
            }
        },
        HExpr::Clone { inner, .. } =>
            collect_c_extern_typed_names(inner, captures, params, externs, out),
        HExpr::Take { source, .. } =>
            collect_c_extern_typed_names(
                source, captures, params, externs, out),
        HExpr::ReturnExpr { value, .. } => match value {
            some(v) => collect_c_extern_typed_names(v, captures, params, externs, out),
            none => {},
        },
        HExpr::UnsafeBlock { body, .. } =>
            collect_c_extern_typed_names(body, captures, params, externs, out),
        _ => {},
    }
}

fn collect_c_extern_typed_names_stmt(
    stmt: HStmt,
    captures: List<Str>,
    params: List<HParam>,
    externs: Set<Str>,
    mut out: Set<Str>
) {
    match stmt {
        HStmt::Let { init, .. } =>
            collect_c_extern_typed_names(init, captures, params, externs, out),
        HStmt::Var { init, .. } =>
            collect_c_extern_typed_names(init, captures, params, externs, out),
        HStmt::Assign { target, value, .. } => {
            collect_c_extern_typed_names(target, captures, params, externs, out)
            collect_c_extern_typed_names(value, captures, params, externs, out)
        },
        HStmt::ExprStmt { expr, .. } =>
            collect_c_extern_typed_names(expr, captures, params, externs, out),
        HStmt::Return { value, .. } => match value {
            some(v) => collect_c_extern_typed_names(v, captures, params, externs, out),
            none => {},
        },
        HStmt::While { condition, body, .. } => {
            collect_c_extern_typed_names(condition, captures, params, externs, out)
            collect_c_extern_typed_names(body, captures, params, externs, out)
        },
        HStmt::ForIn { iterable, body, .. } => {
            collect_c_extern_typed_names(iterable, captures, params, externs, out)
            collect_c_extern_typed_names(body, captures, params, externs, out)
        },
        HStmt::LetDestructure { init, .. } =>
            collect_c_extern_typed_names(init, captures, params, externs, out),
        HStmt::IfLet { expr, then_block, else_block, .. } => {
            collect_c_extern_typed_names(expr, captures, params, externs, out)
            collect_c_extern_typed_names(then_block, captures, params, externs, out)
            match else_block {
                some(eb) => collect_c_extern_typed_names(eb, captures, params, externs, out),
                none => {},
            }
        },
        _ => {},
    }
}

// ============================================================
// Closure calls + dict dispatch (step 5)
// ============================================================

fn emit_c_capture_extract(
    mut ctx: CCtx, edge: CClosureEdge, identity: CTypedRef,
    dest: CTypedRef, index: Int
) {
    if index <= 0 { panic("C codegen: capture extract index must be positive") }
    if c_ref_domain(identity) != c_ref_domain(dest) ||
       c_ref_def_id(identity) != c_ref_def_id(dest) ||
       c_ref_key(identity) != c_ref_key(dest) {
        panic("C codegen: capture extract destination changed identity")
    }
    let dest_name = c_ref_c_name(dest)
    c_emit(ctx, "${dest_name} = ((void**)env)[${index}];")
    c_record_capture_extract(
        ctx, edge, dest, "env", dest_name, index)
}

// Handler parent context has an explicit source→target semantic relation.
// The HIR validator proves that relation; the H+T capture ledger continues to
// pair store/extract on the source identity while the physical child slot is
// the handler-local EffectCtx target.
fn emit_c_effect_ctx_parent_extract(
    mut ctx: CCtx, edge: CClosureEdge, source: CTypedRef,
    dest: CTypedRef, index: Int
) {
    if index <= 0 {
        panic("C codegen: EffectCtx parent extract index must be positive")
    }
    let dest_name = c_ref_c_name(dest)
    c_emit(ctx, "${dest_name} = (EffectCtx*)((void**)env)[${index}];")
    c_record_capture_extract(
        ctx, edge, source, "env", dest_name, index)
}

fn emit_c_capture_store(
    mut ctx: CCtx, edge: CClosureEdge, identity: CTypedRef,
    env: CTypedRef, index: Int
) {
    if index <= 0 { panic("C codegen: capture store index must be positive") }
    let source_name = c_ref_c_name(identity)
    let env_name = c_ref_c_name(env)
    c_emit(ctx, "((void**)${env_name})[${index}] = ${source_name};")
    c_record_capture_store(
        ctx, edge, identity, source_name, env_name, index)
}

fn emit_c_closure_construction(
    mut ctx: CCtx, edge: CClosureEdge, env: CTypedRef,
    lambda_name: Str
) -> CTypedRef {
    rt_use(ctx, "ring_alloc", 2)
    let cls = fresh_tmp(ctx)
    let env_name = c_ref_c_name(env)
    c_emit(ctx, "${cls} = ring_alloc((int64_t)(2 * sizeof(void*)), 7);")
    c_emit(ctx, "((void**)${cls})[0] = (void*)${lambda_name};")
    c_emit(ctx, "((void**)${cls})[1] = ${env_name};")
    let closure_ref = c_ref_fresh(cls, "closure-edge:${lambda_name}")
    c_record_closure_edge(ctx, edge, closure_ref, env_name, cls)
    closure_ref
}

pub fn emit_c_receiver_load(
    mut ctx: CCtx, receiver: CTypedRef, index: Int, role: Str
) -> CTypedRef {
    if index <= 0 { panic("C codegen: receiver load index must be positive") }
    let domain = c_ref_domain(receiver)
    if role == "dict" {
        if domain != "name-only" && domain != "static" && domain != "computed" {
            panic("C codegen: dict receiver has forbidden '${domain}' identity domain")
        }
    } else {
        if role == "effect" {
            if domain != "name-only" && domain != "computed" {
                panic("C codegen: effect receiver has forbidden '${domain}' identity domain")
            }
        } else {
            panic("C codegen: unknown receiver-load role '${role}'")
        }
    }
    let source_name = c_ref_c_name(receiver)
    let dest = fresh_tmp(ctx)
    let load_id = c_fresh_load_id(ctx)
    c_emit(ctx, "${dest} = ((void**)${source_name})[${index}];")
    c_record_receiver_load(
        ctx, role, load_id, receiver, source_name, dest, index)
    c_ref_loaded(dest, "${role}-receiver-load", load_id)
}

// Uniform ordinary closure ABI: env, ordinary args, dictionaries, EffectCtx*.
pub fn gen_c_closure_call(
    mut ctx: CCtx, closure_ref: CTypedRef, arg_vals: List<Str>,
    effect_ctx: TypedEffectCtxSource
) -> Str {
    let closure_val = c_ref_c_name(closure_ref)
    let mut cast_tys: List<Str> = ["void*"]
    let mut call_args: List<Str> = ["((void**)${closure_val})[1]"]
    for a in arg_vals {
        cast_tys.push("void*")
        call_args.push(a)
    }
    cast_tys.push("EffectCtx*")
    call_args.push(c_effect_ctx_source_value(ctx, effect_ctx))
    let t = fresh_tmp(ctx)
    c_emit(ctx, "${t} = ((void* (*)(${cast_tys.join(", ")}))(((void**)${closure_val})[0]))(${call_args.join(", ")});")
    c_record_closure_call(
        ctx, closure_ref, closure_val, t, arg_vals.len() + 2)
    t
}

// Handler operation arms are an explicit internal callable domain. Their
// parent context is owned by the env; they do not receive the child context as
// an ordinary trailing ABI argument.
fn gen_c_handler_arm_call(
    mut ctx: CCtx, closure_ref: CTypedRef, arg_vals: List<Str>
) -> Str {
    let closure_val = c_ref_c_name(closure_ref)
    let mut cast_tys: List<Str> = ["void*"]
    let mut call_args: List<Str> = ["((void**)${closure_val})[1]"]
    for arg in arg_vals {
        cast_tys.push("void*")
        call_args.push(arg)
    }
    let result = fresh_tmp(ctx)
    c_emit(ctx,
        "${result} = ((void* (*)(${cast_tys.join(", ")}))(((void**)${closure_val})[0]))(${call_args.join(", ")});")
    c_record_closure_call(
        ctx, closure_ref, closure_val, result, arg_vals.len() + 1)
    result
}

// Trait method call through exact dictionary evidence:
// load exact evidence, read the resolver-issued callable slot, and call it.
fn gen_c_bound_method_call(
    mut ctx: CCtx, callee: HExpr, args: List<HExpr>, exact: MethodCallRef,
    resolved_dicts: List<DictRef>, effect_ctx: TypedEffectCtxSource
) -> Str {
    // Receiver from callee (FieldAccess) or first arg.
    let mut call_args: List<Str> = []
    let mut other_arg_start = 0
    match callee {
        HExpr::FieldAccess { receiver, .. } => {
            call_args.push(gen_c_expr(ctx, receiver))
        },
        _ => {
            match args.get(0) {
                some(a) => {
                    call_args.push(gen_c_expr(ctx, a))
                    other_arg_start = 1
                },
                none => {},
            }
        },
    }
    for i in other_arg_start..args.len() {
        match args.get(i) {
            some(a) => call_args.push(gen_c_expr(ctx, a)),
            none => {},
        }
    }
    for value in resolved_dicts {
        call_args.push(c_ref_c_name(c_resolve_dict_ref(ctx, value)))
    }

    let dict_ref = c_resolve_dict_ref(
        ctx, method_call_ref_bound_evidence(exact))
    let method_idx = trait_method_ref_callable_slot_index(
        method_call_ref_bound(exact))
    let cls_ref = emit_c_receiver_load(
        ctx, dict_ref, method_idx + 1, "dict")
    gen_c_closure_call(ctx, cls_ref, call_args, effect_ctx)
}

// ============================================================
// Eq / Ord trait dispatch (ports of gen_eq_dispatch_llvm / gen_ord_dispatch_llvm)
// ============================================================

fn resolve_c_dispatch_dict(
    mut ctx: CCtx, dispatch: TraitDispatch, trait_name_hint: Str?
) -> CTypedRef {
    match dispatch {
        TraitDispatch::Dict { param } => {
            c_resolve_simple_dict_name(ctx, param)
        },
        TraitDispatch::Direct { dict, extra_dicts } => {
            let _ = dict
            let _ = extra_dicts
            let _ = trait_name_hint
            panic("C codegen: legacy name-only Direct dispatch crossed Core bridge")
        },
        TraitDispatch::Builtin => c_ref_computed(
            "RING_UNIT", "builtin-dispatch"),
        TraitDispatch::Tuple { .. } =>
            panic("C codegen: tuple dispatch must be consumed structurally"),
    }
}

fn emit_c_builtin_eq_raw(mut ctx: CCtx, lhs: Str, rhs: Str, ty: Type) -> Str {
    let raw = fresh_i64(ctx)
    if is_int_type(ty) || is_bool_type(ty) || is_unit_type(ty) {
        c_emit(ctx, "${raw} = RING_UNTAG(${lhs}) == RING_UNTAG(${rhs});")
    } else if is_float_type(ty) {
        rt_use(ctx, "ring_unbox_float", 1)
        c_emit(ctx, "${raw} = ring_unbox_float(${lhs}) == ring_unbox_float(${rhs});")
    } else if is_str_type(ty) {
        rt_use(ctx, "ring_str_eq", 2)
        c_emit(ctx, "${raw} = ring_str_eq(${lhs}, ${rhs});")
    } else {
        match ty {
            // Preserve the existing identity semantics of the builtin
            // Unit/Never/Any leaves. Never is unreachable in a well-typed
            // running program; Any uses the same tagged-word comparison as
            // the old BinOp fallback.
            Type::NeverType | Type::AnyType =>
                c_emit(ctx, "${raw} = RING_UNTAG(${lhs}) == RING_UNTAG(${rhs});"),
            _ => panic("C codegen: non-primitive Builtin in tuple Eq plan"),
        }
    }
    raw
}

fn emit_c_tuple_eq_raw(mut ctx: CCtx, lhs: Str, rhs: Str, tuple_ty: Type,
                       element_types: List<Type>, elements: List<TraitDispatch>) -> Str {
    let tuple_arity = match tuple_ty {
        Type::TupleType { elements: tuple_elements } => tuple_elements.len(),
        _ => panic("C codegen: tuple Eq plan applied to non-tuple type"),
    }
    if tuple_arity != element_types.len() || tuple_arity != elements.len() {
        panic("C codegen: tuple Eq plan/arity mismatch")
    }

    let result = fresh_i64(ctx)
    c_emit(ctx, "${result} = 1;")
    rt_use(ctx, "ring_list_get", 2)
    for i in 0..tuple_arity {
        // A statement-level guard gives strict left-to-right short circuiting.
        // Both tuple operands were materialised once by gen_c_eq_dispatch.
        c_emit(ctx, "if (${result}) {")
        ctx.indent = ctx.indent + 1
        let lhs_element = fresh_tmp(ctx)
        let rhs_element = fresh_tmp(ctx)
        c_emit(ctx, "${lhs_element} = ring_list_get(${lhs}, ${i});")
        c_emit(ctx, "${rhs_element} = ring_list_get(${rhs}, ${i});")
        let element_result = emit_c_eq_raw(
            ctx, lhs_element, rhs_element, element_types[i], elements[i])
        c_emit(ctx, "${result} = ${element_result};")
        ctx.indent = ctx.indent - 1
        c_emit(ctx, "}")
    }
    result
}

fn emit_c_eq_raw(mut ctx: CCtx, lhs: Str, rhs: Str, ty: Type,
                 dispatch: TraitDispatch) -> Str {
    match dispatch {
        TraitDispatch::Builtin => emit_c_builtin_eq_raw(ctx, lhs, rhs, ty),
        TraitDispatch::Direct { dict, extra_dicts } => {
            // A parameterized Direct dispatch is resolved by constructing a
            // fresh DICT_DYN wrapper.  It owns its method closures/envs and
            // must die after the borrowed method call; plain Direct and Dict
            // dispatches are static/borrowed and must never be dropped here.
            let owns_dict_wrapper = extra_dicts.len() > 0
            let dict_ref = resolve_c_dispatch_dict(
                ctx, TraitDispatch::Direct { dict: dict, extra_dicts: extra_dicts }, some("Eq"))
            let cls_ref = emit_c_receiver_load(ctx, dict_ref, 1, "dict")
            let result = gen_c_closure_call(
                ctx, cls_ref, [lhs, rhs], make_empty_effect_ctx_source())
            let raw = fresh_i64(ctx)
            c_emit(ctx, "${raw} = RING_UNTAG(${result});")
            // The dispatch result is internal to structural comparison.
            rt_use(ctx, "ring_drop", 1)
            c_emit(ctx, "ring_drop(${result});")
            if owns_dict_wrapper {
                let dict_ptr = c_ref_c_name(dict_ref)
                c_emit(ctx, "ring_drop(${dict_ptr});")
            }
            raw
        },
        TraitDispatch::Dict { param } => {
            let dict_ref = resolve_c_dispatch_dict(
                ctx, TraitDispatch::Dict { param: param }, some("Eq"))
            let cls_ref = emit_c_receiver_load(ctx, dict_ref, 1, "dict")
            let result = gen_c_closure_call(
                ctx, cls_ref, [lhs, rhs], make_empty_effect_ctx_source())
            let raw = fresh_i64(ctx)
            c_emit(ctx, "${raw} = RING_UNTAG(${result});")
            rt_use(ctx, "ring_drop", 1)
            c_emit(ctx, "ring_drop(${result});")
            raw
        },
        TraitDispatch::Tuple { element_types, elements } =>
            emit_c_tuple_eq_raw(ctx, lhs, rhs, ty, element_types, elements),
    }
}

fn gen_c_eq_dispatch(mut ctx: CCtx, op: BinOp, left: HExpr, right: HExpr, dispatch: TraitDispatch) -> Str {
    let operand_ty = hexpr_type(left)
    let lhs = gen_c_expr(ctx, left)
    let rhs = gen_c_expr(ctx, right)
    let raw = emit_c_eq_raw(ctx, lhs, rhs, operand_ty, dispatch)
    let result = fresh_tmp(ctx)
    match op {
        BinOp::Neq => c_emit(ctx, "${result} = RING_BOOL(1 - ${raw});"),
        _ => c_emit(ctx, "${result} = RING_BOOL(${raw});"),
    }
    result
}

fn gen_c_ord_dispatch(mut ctx: CCtx, op: BinOp, left: HExpr, right: HExpr, dispatch: TraitDispatch) -> Str {
    let lhs = gen_c_expr(ctx, left)
    let rhs = gen_c_expr(ctx, right)
    let dict_ref = resolve_c_dispatch_dict(ctx, dispatch, some("Ord"))
    let cls_ref = emit_c_receiver_load(ctx, dict_ref, 1, "dict")
    let result = gen_c_closure_call(
        ctx, cls_ref, [lhs, rhs], make_empty_effect_ctx_source())
    // The cmp INT box is INTERNAL — unbox, drop, compare against 0.
    let raw = fresh_i64(ctx)
    c_emit(ctx, "${raw} = RING_UNTAG(${result});")
    rt_use(ctx, "ring_drop", 1)
    c_emit(ctx, "ring_drop(${result});")
    let cmp = match op {
        BinOp::Lt => "<",
        BinOp::Lte => "<=",
        BinOp::Gt => ">",
        BinOp::Gte => ">=",
        _ => "==",
    }
    let t = fresh_tmp(ctx)
    c_emit(ctx, "${t} = RING_BOOL(${raw} ${cmp} 0);")
    t
}

// ============================================================
// Step 6: effect handlers (tail-resumptive + abort) + try/catch.
//
// Mechanism is the LLVM backend's, rendered as C text (plan §2.1: read the
// existing implementation first, map it verbatim):
//   * fail/abort   = setjmp/longjmp.  ring_catch_push() allocates a runtime
//     catch frame; the standard C `setjmp` macro (not the raw _setjmp symbol —
//     clang's <setjmp.h> handles the Windows x64 frame-pointer ABI that the
//     LLVM backend passes by hand via @llvm.frameaddress) arms its jmp_buf;
//     `fail.raise` calls ring_raise = longjmp into the innermost frame.
//   * tail-resumptive handler ops = evidence structs.  An evidence struct is
//     { int64_t count, void* slot0, ... } (typeid 21, RING_TYPEID_EVIDENCE);
//     slot k holds op k's {fn_ptr, env} closure (slot order = declaration
//     order via exact EffectOperationRef source ordinals). Handler arms become closures via
//     gen_c_lambda; an effect op dispatches by loading its slot and calling
//     the closure — the arm's return value IS the resume value.
//   * setjmp non-volatile-local caveat: all Ring locals are hoisted to the
//     function top and clang marks setjmp returns_twice, forcing the same
//     conservative spill treatment the LLVM backend gets from entry-block
//     allocas + returns_twice on _setjmp.  See worker_feedback step 6.
// ============================================================

// Register the four runtime catch-frame helpers.
fn rt_use_catch_fns(mut ctx: CCtx) {
    rt_use(ctx, "ring_catch_push", 0)
    rt_use(ctx, "ring_catch_get_buf", 1)
    rt_use(ctx, "ring_catch_get_error", 1)
    rt_use(ctx, "ring_catch_pop", 0)
}

// #173/#193: walk enclosing control scopes innermost-first and pop catch
// frames. All resource cleanup, including EffectCtx, is explicit RcHIR.
fn emit_c_cleanup_walk(mut ctx: CCtx) {
    let n = ctx.handle_cleanup_stack.len()
    for i in 0..n {
        match ctx.handle_cleanup_stack.get(n - 1 - i) {
            some(cleanup) => {
                if cleanup.needs_catch_pop {
                    rt_use(ctx, "ring_catch_pop", 0)
                    c_emit(ctx, "ring_catch_pop();")
                }
            },
            none => {},
        }
    }
}

// TryCatch — inline setjmp (B-089 G-b port of gen_try_catch).  Body and catch
// arms execute in the current C stack frame, sharing all hoisted locals.
fn gen_c_try_catch(mut ctx: CCtx, body: HExpr, arms: List<HMatchArm>) -> Str {
    rt_use_catch_fns(ctx)
    let frame = fresh_tmp(ctx)
    let buf = fresh_tmp(ctx)
    let res = fresh_tmp(ctx)
    let catch_lbl = fresh_label(ctx, "catch")
    let merge_lbl = fresh_label(ctx, "cmerge")

    c_emit(ctx, "${frame} = ring_catch_push();")
    c_emit(ctx, "${buf} = ring_catch_get_buf(${frame});")
    // setjmp must be the whole controlling expression of the if (C11
    // 7.13.1.1p5) — never assigned to a temporary.
    c_emit(ctx, "if (setjmp(*(jmp_buf*)${buf}) != 0) goto ${catch_lbl};")

    // --- normal path: body inline, pop frame ---
    // #173: a `return` inside the body must pop this catch frame.
    ctx.handle_cleanup_stack.push(CHandleCleanup {
        needs_catch_pop: true })
    let body_val = gen_c_expr(ctx, body)
    let _popped = ctx.handle_cleanup_stack.pop()
    c_emit(ctx, "${res} = ${body_val};")
    c_emit(ctx, "ring_catch_pop();")
    c_emit(ctx, "goto ${merge_lbl};")

    // --- catch path: get error, pop frame, run catch arms inline ---
    c_raw(ctx, "${catch_lbl}:;")
    let err = fresh_tmp(ctx)
    c_emit(ctx, "${err} = ring_catch_get_error(${frame});")
    c_emit(ctx, "ring_catch_pop();")
    // Catch arms reuse the unified match test-and-fall-through chain — this
    // runs the FULL nested pattern check (ctor tags at every depth, literal
    // sub-patterns, guards) per arm, so audit #246's LLVM defect (top-level
    // tag test only) is NOT ported.
    for arm in arms {
        emit_c_match_arm(ctx, arm, err, res, merge_lbl)
    }
    // Exhaustion default: the checker guarantees catch-arm exhaustiveness, so
    // this is unreachable in well-typed programs.  C panics (same stable
    // deviation from LLVM `unreachable` as gen_c_match_expr).
    ctx.match_counter = ctx.match_counter + 1
    let msg = gen_c_str_lit(ctx, "catch exhaustion failure #${ctx.match_counter}")
    rt_use(ctx, "ring_panic", 1)
    c_emit(ctx, "ring_panic(${msg});")

    c_raw(ctx, "${merge_lbl}:;")
    res
}

// Handle expression. Each custom handle builds owned evidence objects, then
// transfers them into one owned child overlay keyed by Core/Rc-issued tokens.
fn gen_c_handle_expr(
    mut ctx: CCtx, body: HExpr, handlers: List<HEffectHandler>,
    effect_ctx_install: TypedEffectCtxInstall?
) -> Str {
    let mut abort_handler: HEffectHandler? = none
    let mut has_custom_handler = false
    for h in handlers {
        if h.handled_instance.is_some() { has_custom_handler = true }
        if h.fail_ref.is_some() {
            match abort_handler {
                some(_) => panic("C codegen: duplicate fail handler"),
                none => { abort_handler = some(h) },
            }
        }
    }

    let has_fail_abort = abort_handler.is_some()
    match effect_ctx_install {
        some(install) => {
            if !has_custom_handler {
                panic("C codegen: EffectCtx install has no custom handlers")
            }
            let entries = typed_effect_ctx_install_entries(install)
            if entries.len() == 0 {
                panic("C codegen: EffectCtx install is empty")
            }
            let parent_ref = c_effect_ctx_ref(
                ctx, typed_effect_ctx_install_parent(install))
            let child_slot = c_local_effect_ctx_slot(
                ctx, effect_ctx_slot(
                    typed_effect_ctx_install_child(install)),
                "__effect_ctx_child")
            let child_name = c_exact_slot_c_name(child_slot)
            let token_array = fresh_effect_ctx_token_array(
                ctx, entries.len())
            let evidence_array = fresh_effect_ctx_evidence_array(
                ctx, entries.len())

            for index in 0..entries.len() {
                let entry = entries.get(index).unwrap()
                let mut entry_handlers: List<HEffectHandler> = []
                for handler in handlers {
                    match handler.handled_instance {
                        some(instance) => if
                                typed_handled_effect_instance_same(
                                    instance, entry) {
                            entry_handlers.push(handler)
                        },
                        none => {}
                    }
                }
                if entry_handlers.len() == 0 {
                    panic("C codegen: EffectCtx entry has no handlers")
                }
                let evidence = build_c_handler_evidence(
                    ctx, entry, entry_handlers)
                c_emit(ctx, "${token_array}[${index}] = ${c_effect_ctx_token_value(ctx, entry)};")
                c_emit(ctx, "${evidence_array}[${index}] = ${evidence};")
            }
            for handler in handlers {
                match handler.handled_instance {
                    some(instance) => {
                        let mut matches = 0
                        for entry in entries {
                            if typed_handled_effect_instance_same(
                                    instance, entry) {
                                matches = matches + 1
                            }
                        }
                        if matches != 1 {
                            panic("C codegen: handler/install instance differs")
                        }
                    },
                    none => if handler.fail_ref.is_none() {
                        panic("C codegen: handler lacks typed identity")
                    }
                }
            }
            rt_use_raw(ctx, "ring_effect_ctx_overlay",
                "EffectCtx* ring_effect_ctx_overlay(EffectCtx* parent, int64_t entry_count, const void* const* tokens, void* const* evidence_values);")
            c_emit(ctx,
                "${child_name} = ring_effect_ctx_overlay(${c_ref_c_name(parent_ref)}, ${entries.len()}, ${token_array}, ${evidence_array});")
        },
        none => if has_custom_handler {
            panic("C codegen: custom handlers lack EffectCtx install")
        }
    }

    if has_fail_abort {
        // Abort (fail.raise) handler: inline setjmp like gen_c_try_catch. On
        // the catch path deactivates the current frame first, then
        // the payload is bound and the abort arm executes exactly once.
        rt_use_catch_fns(ctx)
        let frame = fresh_tmp(ctx)
        let buf = fresh_tmp(ctx)
        let res = fresh_tmp(ctx)
        let catch_lbl = fresh_label(ctx, "hcatch")
        let merge_lbl = fresh_label(ctx, "hmerge")

        c_emit(ctx, "${frame} = ring_catch_push();")
        c_emit(ctx, "${buf} = ring_catch_get_buf(${frame});")
        c_emit(ctx, "if (setjmp(*(jmp_buf*)${buf}) != 0) goto ${catch_lbl};")

        // --- normal path ---
        ctx.handle_cleanup_stack.push(CHandleCleanup {
            needs_catch_pop: true })
        let body_val = gen_c_expr(ctx, body)
        let _popped = ctx.handle_cleanup_stack.pop()
        c_emit(ctx, "${res} = ${body_val};")
        c_emit(ctx, "ring_catch_pop();")
        c_emit(ctx, "goto ${merge_lbl};")

        // --- catch path: deactivate current handle, then execute abort arm ---
        c_raw(ctx, "${catch_lbl}:;")
        let error_val = fresh_tmp(ctx)
        c_emit(ctx, "${error_val} = ring_catch_get_error(${frame});")
        c_emit(ctx, "ring_catch_pop();")

        // The operation parameter is a lexical binder. Isolate it from the
        // enclosing map so a same-named outer local is restored at the merge.
        let saved_arm_named = ctx.named_values
        ctx.named_values = map_clone(saved_arm_named)
        let arm_val = match abort_handler {
            some(h) => {
                let parent_source = c_effect_ctx_ref(
                    ctx, effect_ctx_parent_capture_source(h.parent_ctx))
                let parent_target = effect_ctx_slot(
                    effect_ctx_parent_capture_target(h.parent_ctx))
                let parent_slot = c_local_effect_ctx_slot(
                    ctx, parent_target, "__effect_ctx_parent")
                c_emit(ctx, "${c_exact_slot_c_name(parent_slot)} = ${c_ref_c_name(parent_source)};")
                let mut param_index = 0
                for p in h.params {
                    let pv = c_local_def(ctx, p.name, p.def_id)
                    if param_index == 0 {
                        c_emit(ctx, "${pv} = ${error_val};")
                    } else {
                        c_emit(ctx, "${pv} = RING_UNIT;")
                    }
                    param_index = param_index + 1
                }
                gen_c_expr(ctx, h.body)
            },
            // Defensive fallback for malformed HIR; checked source always has
            // the fail.raise handler that set has_fail_abort.
            none => error_val,
        }
        c_emit(ctx, "${res} = ${arm_val};")
        ctx.named_values = saved_arm_named

        c_raw(ctx, "${merge_lbl}:;")
        res
    } else {
        // No custom install: execute the body with the existing context.
        ctx.handle_cleanup_stack.push(CHandleCleanup {
            needs_catch_pop: false })
        let result = gen_c_expr(ctx, body)
        let _popped = ctx.handle_cleanup_stack.pop()
        // The result may be a pure-constant expression — materialise it
        // before leaving the handle lowering.
        let res = fresh_tmp(ctx)
        c_emit(ctx, "${res} = ${result};")
        res
    }
}

// B-090 (D1) / B-096 / B-097 / B-161: construct the evidence struct for one
// handled effect (port of build_handler_evidence).
// Layout: { int64_t count, void* slot0, ... }, typeid 21 (RING_TYPEID_EVIDENCE)
// — drop_evidence (runtime) reads the leading count and ring_drop's each
// non-null closure slot.  Slot k = op k's closure (declaration order).
fn build_c_handler_evidence(
    mut ctx: CCtx, installed: TypedHandledEffectInstance,
    hs: List<HEffectHandler>
) -> Str {
    let requirement = typed_handled_effect_instance_reference(installed)
    let n_slots = hs.len()
    let mut seen: Set<Int> = set_new()
    for handler in hs {
        match handler.handled_instance {
            some(instance) => if !typed_handled_effect_instance_same(
                    instance, installed) {
                panic("C codegen: handler typed instance differs")
            },
            none => panic("C codegen: custom handler lacks typed instance")
        }
        let operation = match handler.operation_ref {
            some(value) => value,
            none => panic("C codegen: custom handler lacks operation ref")
        }
        if !handled_effect_ref_same(
                effect_operation_ref_effect(operation), requirement) {
            panic("C codegen: handler operation crosses installed effect")
        }
        let index = effect_operation_ref_source_index(operation)
        if index < 0 || index >= n_slots || seen.contains(index) {
            panic("C codegen: handler operation order/census differs")
        }
        seen.insert(index)
    }
    if seen.len() != n_slots {
        panic("C codegen: handler operation set is incomplete")
    }

    rt_use(ctx, "ring_alloc", 2)
    let ev = fresh_tmp(ctx)
    c_emit(ctx, "${ev} = ring_alloc((int64_t)(sizeof(int64_t) + ${n_slots} * sizeof(void*)), 21);")
    c_emit(ctx, "*(int64_t*)${ev} = ${n_slots};")
    // Null-init every slot. Missing custom handlers are rejected before C.
    for i in 0..n_slots {
        c_emit(ctx, "((void**)${ev})[${i + 1}] = 0;")
    }

    // One closure per handler arm, stored at its declared op slot.  The arm's
    // return value is the resume value (tail-resumptive), so the closure
    // simply returns its body.
    for h in hs {
        let operation = match h.operation_ref {
            some(value) => value,
            none => panic("C codegen: custom handler lost exact operation")
        }
        let idx = effect_operation_ref_source_index(operation)
        let arm_closure = gen_c_handler_arm(ctx, h)
        c_emit(ctx, "((void**)${ev})[${idx + 1}] = ${arm_closure};")
    }

    ev
}

// Effect operation — port of gen_effect_op.
fn gen_c_effect_op(
    mut ctx: CCtx, effect_name: Str, op_name: Str,
    operation_ref: EffectOperationRef?,
    effect_ctx_lookup: TypedEffectCtxLookup?, args: List<HExpr>
) -> Str {
    if operation_ref.is_none() {
        if effect_name != "fail" || op_name != "raise" ||
           effect_ctx_lookup.is_some() {
            panic("C codegen: non-custom effect operation contract differs")
        }
        // Abort: ring_raise longjmps into the innermost catch frame.
        let mut arg_vals: List<Str> = []
        for a in args { arg_vals.push(gen_c_expr(ctx, a)) }
        rt_use(ctx, "ring_raise", 1)
        let error_val = match arg_vals.get(0) {
            some(v) => v,
            none => "RING_UNIT",
        }
        c_emit(ctx, "ring_raise(${error_val});")
        // ring_raise never returns; any following C statements are dead.
        "RING_UNIT"
    } else {
        let operation = operation_ref.unwrap()
        let lookup = match effect_ctx_lookup {
            some(value) => value,
            none => panic("C codegen: custom effect operation lacks ctx lookup")
        }
        if !handled_effect_ref_same(
                typed_handled_effect_instance_reference(
                    typed_effect_ctx_lookup_instance(lookup)),
                effect_operation_ref_effect(operation)) {
            panic("C codegen: effect operation typed lookup differs")
        }
        let mut arg_vals: List<Str> = []
        for arg in args { arg_vals.push(gen_c_expr(ctx, arg)) }
        let instance = typed_effect_ctx_lookup_instance(lookup)
        let context = c_effect_ctx_ref(
            ctx, typed_effect_ctx_lookup_context(lookup))
        rt_use_raw(ctx, "ring_effect_ctx_lookup",
            "void* ring_effect_ctx_lookup(const EffectCtx* ctx, const void* token);")
        let evidence = fresh_tmp(ctx)
        c_emit(ctx,
            "${evidence} = ring_effect_ctx_lookup(${c_ref_c_name(context)}, ${c_effect_ctx_token_value(ctx, instance)});")
        let missing = c_interned_cstr(
            ctx, "unhandled typed effect operation")
        rt_use(ctx, "ring_str_from_cstr", 1)
        rt_use(ctx, "ring_panic", 1)
        c_emit(ctx,
            "if (${evidence} == NULL) ring_panic(ring_str_from_cstr(${missing}));")
        let index = effect_operation_ref_source_index(operation)
        if index < 0 {
            panic("C codegen: negative effect operation index")
        }
        let closure_ref = emit_c_receiver_load(
            ctx, c_ref_computed(evidence, "effect-ctx-lookup"),
            index + 1, "effect")
        gen_c_handler_arm_call(ctx, closure_ref, arg_vals)
    }
}

// Empty entries are exact inline-only sites; every non-empty entry names the
// sole runtime ABI target for its BuiltinMethodSite.
const INTRINSIC_RUNTIME_NAMES: List<Str> = [
    "ring_str_len", "ring_str_contains", "ring_str_starts_with",
    "ring_str_ends_with", "ring_str_slice", "ring_str_trim",
    "ring_str_to_upper", "ring_str_to_lower", "ring_str_replace",
    "ring_str_split", "ring_str_char_at", "ring_str_index_of",
    "ring_str_pad_start", "ring_str_pad_end", "ring_str_repeat",
    "ring_str_char_code_at", "ring_str_trim_start", "ring_str_trim_end",
    "ring_str_is_empty", "ring_str_last_index_of", "ring_int_to_str",
    "ring_float_to_str", "ring_Option_unwrap_or", "ring_Option_unwrap",
    "ring_Option_is_some", "ring_Option_is_none", "ring_Option_map",
    "ring_Option_and_then", "ring_Option_unwrap_or_else",
    "ring_Option_to_fail", "ring_Cell_get", "ring_Cell_set",
    "ring_Cell_update",
    "ring_cl_eq_int", "ring_cl_ne_int",
    "ring_cl_eq_float", "ring_cl_ne_float",
    "ring_cl_eq_str", "ring_cl_ne_str",
    "ring_cl_eq_bool", "ring_cl_ne_bool",
    "ring_dup", "ring_dup", "ring_dup", "ring_dup",
    "ring_cl_cmp_int", "ring_cl_cmp_float",
    "ring_cl_cmp_str", "ring_cl_cmp_bool",
    "ring_cl_debug_int", "ring_cl_debug_float",
    "ring_cl_debug_str", "ring_cl_debug_bool",
    "ring_cl_hash_int_export", "ring_cl_hash_str_export",
    "ring_cl_hash_bool_export",
    "", "", "", "", "", ""
]

fn validate_c_callback_intrinsic_census() {
    let expected: List<(Int, Str)> = [
        (BUILTIN_METHOD_OPTION_MAP, "ring_Option_map"),
        (BUILTIN_METHOD_OPTION_AND_THEN, "ring_Option_and_then"),
        (BUILTIN_METHOD_OPTION_UNWRAP_OR_ELSE,
            "ring_Option_unwrap_or_else"),
        (BUILTIN_METHOD_CELL_UPDATE, "ring_Cell_update")
    ]
    for entry in expected {
        let (tag, runtime_name) = entry
        if INTRINSIC_RUNTIME_NAMES.get(tag).unwrap_or("") != runtime_name ||
           !intrinsic_is_callback_leaf(tag) {
            panic("C codegen: callback intrinsic census differs")
        }
    }
    for tag in 0..BUILTIN_METHOD_SITE_COUNT {
        let mut should_be_callback = false
        for entry in expected {
            let (expected_tag, _runtime_name) = entry
            if tag == expected_tag { should_be_callback = true }
        }
        if intrinsic_is_callback_leaf(tag) != should_be_callback {
            panic("C codegen: callback intrinsic census differs")
        }
    }
    let mut found = 0
    for runtime_name in INTRINSIC_RUNTIME_NAMES {
        if runtime_name == "ring_Option_map" ||
           runtime_name == "ring_Option_and_then" ||
           runtime_name == "ring_Option_unwrap_or_else" ||
           runtime_name == "ring_Cell_update" {
            found = found + 1
        }
    }
    if found != expected.len() {
        panic("C codegen: callback intrinsic census differs")
    }
}

fn intrinsic_runtime_name(tag: Int) -> Str {
    validate_c_callback_intrinsic_census()
    if INTRINSIC_RUNTIME_NAMES.len() != BUILTIN_METHOD_SITE_COUNT ||
       tag < 0 || tag >= BUILTIN_METHOD_SITE_COUNT {
        panic("C codegen: builtin method intrinsic census drifted")
    }
    INTRINSIC_RUNTIME_NAMES.get(tag).unwrap_or("")
}

fn intrinsic_is_scalar_clone(tag: Int) -> Bool {
    tag == BUILTIN_METHOD_INT_CLONE ||
    tag == BUILTIN_METHOD_FLOAT_CLONE ||
    tag == BUILTIN_METHOD_STR_CLONE ||
    tag == BUILTIN_METHOD_BOOL_CLONE
}

fn intrinsic_uses_closure_abi(tag: Int) -> Bool {
    tag >= BUILTIN_METHOD_INT_EQ && !intrinsic_is_scalar_clone(tag)
}

fn intrinsic_is_callback_leaf(tag: Int) -> Bool {
    tag == BUILTIN_METHOD_OPTION_MAP ||
    tag == BUILTIN_METHOD_OPTION_AND_THEN ||
    tag == BUILTIN_METHOD_OPTION_UNWRAP_OR_ELSE ||
    tag == BUILTIN_METHOD_CELL_UPDATE
}

fn intrinsic_is_ptr(tag: Int) -> Bool {
    tag >= BUILTIN_METHOD_PTR_ADDR && tag <= BUILTIN_METHOD_PTR_WRITE
}

fn intrinsic_returns_raw_i64(tag: Int) -> Bool {
    tag == BUILTIN_METHOD_STR_LEN ||
    tag == BUILTIN_METHOD_STR_CONTAINS ||
    tag == BUILTIN_METHOD_STR_STARTS_WITH ||
    tag == BUILTIN_METHOD_STR_ENDS_WITH ||
    tag == BUILTIN_METHOD_STR_IS_EMPTY ||
    tag == BUILTIN_METHOD_OPTION_IS_SOME ||
    tag == BUILTIN_METHOD_OPTION_IS_NONE
}

fn intrinsic_returns_bool(tag: Int) -> Bool {
    tag == BUILTIN_METHOD_STR_CONTAINS ||
    tag == BUILTIN_METHOD_STR_STARTS_WITH ||
    tag == BUILTIN_METHOD_STR_ENDS_WITH ||
    tag == BUILTIN_METHOD_STR_IS_EMPTY ||
    tag == BUILTIN_METHOD_OPTION_IS_SOME ||
    tag == BUILTIN_METHOD_OPTION_IS_NONE
}

fn intrinsic_int_arg_count(tag: Int) -> Int {
    if tag == BUILTIN_METHOD_STR_SLICE { 2 }
    else if tag == BUILTIN_METHOD_STR_CHAR_AT ||
            tag == BUILTIN_METHOD_STR_CHAR_CODE_AT ||
            tag == BUILTIN_METHOD_STR_PAD_START ||
            tag == BUILTIN_METHOD_STR_PAD_END ||
            tag == BUILTIN_METHOD_STR_REPEAT { 1 }
    else { 0 }
}

fn gen_c_intrinsic_method_call(
    mut ctx: CCtx, callee: HExpr, receiver: Str, receiver_type: Type,
    method_ref: MethodCallRef,
    arg_vals: List<Str>, effect_ctx: TypedEffectCtxSource
) -> Str {
    if !types_equal(method_call_ref_signature(method_ref), hexpr_type(callee)) {
        panic("C codegen: intrinsic method signature drifted")
    }
    let tag = builtin_method_site_tag(intrinsic_ref_site(
        method_call_ref_intrinsic(method_ref)))
    if INTRINSIC_RUNTIME_NAMES.len() != BUILTIN_METHOD_SITE_COUNT {
        panic("C codegen: builtin method intrinsic census drifted")
    }
    if intrinsic_is_ptr(tag) {
        return gen_c_ptr_intrinsic(
            ctx, receiver, receiver_type, tag, arg_vals)
    }
    if intrinsic_is_scalar_clone(tag) {
        rt_use(ctx, "ring_dup", 1)
        c_emit(ctx, "ring_dup(${receiver});")
        return receiver
    }
    let runtime_name = intrinsic_runtime_name(tag)
    let mut call_args: List<Str> = []
    if intrinsic_uses_closure_abi(tag) {
        call_args.push("RING_UNIT")
        call_args.push(receiver)
    } else if tag == BUILTIN_METHOD_INT_TO_STR {
        call_args.push("RING_UNTAG(${receiver})")
    } else if tag == BUILTIN_METHOD_FLOAT_TO_STR {
        rt_use(ctx, "ring_unbox_float", 1)
        call_args.push("ring_unbox_float(${receiver})")
    } else {
        call_args.push(receiver)
    }
    let int_arg_count = intrinsic_int_arg_count(tag)
    let mut index = 0
    for arg in arg_vals {
        if index < int_arg_count {
            call_args.push("RING_UNTAG(${arg})")
        } else {
            call_args.push(arg)
        }
        index = index + 1
    }
    if intrinsic_uses_closure_abi(tag) ||
       intrinsic_is_callback_leaf(tag) {
        call_args.push(c_effect_ctx_source_value(ctx, effect_ctx))
    }
    match rt_known_arity(runtime_name) {
        some(expected) => if call_args.len() != expected {
            panic("C codegen: exact intrinsic runtime arity differs")
        },
        none => panic("C codegen: exact intrinsic lacks runtime ABI")
    }
    rt_use(ctx, runtime_name, call_args.len())
    let result = fresh_tmp(ctx)
    if intrinsic_returns_bool(tag) {
        c_emit(ctx, "${result} = RING_BOOL(${runtime_name}(${call_args.join(", ")}));")
    } else if intrinsic_returns_raw_i64(tag) {
        c_emit(ctx, "${result} = RING_INT(${runtime_name}(${call_args.join(", ")}));")
    } else {
        c_emit(ctx, "${result} = ${runtime_name}(${call_args.join(", ")});")
    }
    result
}

fn gen_c_call(
    mut ctx: CCtx, callee: HExpr, args: List<HExpr>,
    resolved_dicts: List<DictRef>,
    effect_ctx: TypedEffectCtxSource, callee_ref: CalleeRef?,
    method_ref: MethodCallRef?,
    system_host: SystemHostCallableRef?,
    result_ty: Type
) -> Str {
    // Bound dispatch consumes the exact TraitMethodRef slot and DictRef
    // evidence carried by MethodCallRef. Unit-returning dispatch yields
    // RING_UNIT rather than exposing the closure ABI return value.
    match method_ref {
        some(exact) => if method_call_ref_is_bound(exact) {
            let raw = gen_c_bound_method_call(
                ctx, callee, args, exact, resolved_dicts, effect_ctx)
            if is_unit_type(result_ty) {
                return "RING_UNIT"
            }
            return raw
        },
        none => {}
    }

    let mut_flags = c_lookup_call_mut_flags(
        ctx, callee, callee_ref, method_ref)

    // The public evaluation order is receiver before arguments.  Materialize
    // its Rc wrapper now so later argument Take/Drop cannot invalidate it.
    let method_receiver = match method_ref {
        some(exact) => if method_call_ref_is_intrinsic(exact) ||
                           method_call_ref_is_concrete(exact) {
            match callee {
                HExpr::FieldAccess { receiver, .. } =>
                    some((gen_c_expr(ctx, receiver), hexpr_type(receiver))),
                _ => panic("C codegen: exact method has no receiver")
            }
        } else { none },
        none => none
    }

    // Then evaluate arguments left-to-right (mut value positions box cells).
    let mut arg_vals: List<Str> = []
    let mut argi = 0
    for a in args {
        let is_mut = match mut_flags {
            some(flags) => match flags.get(argi) { some(f) => f, none => false },
            none => false,
        }
        if is_mut {
            arg_vals.push(gen_c_mut_arg(ctx, a))
        } else {
            arg_vals.push(gen_c_expr(ctx, a))
        }
        argi = argi + 1
    }

    let mut dict_vals: List<Str> = []
    for dr in resolved_dicts {
        let reference = c_resolve_dict_ref(ctx, dr)
        dict_vals.push(c_ref_c_name(reference))
    }
    match method_ref {
        some(exact_method) => {
            let raw = if method_call_ref_is_intrinsic(exact_method) {
                let receiver = method_receiver.unwrap()
                gen_c_intrinsic_method_call(
                    ctx, callee, receiver.0, receiver.1,
                    exact_method, arg_vals, effect_ctx)
            } else if method_call_ref_is_concrete(exact_method) {
                let receiver = method_receiver.unwrap()
                let method_identity = method_call_ref_impl(exact_method)
                gen_c_method_call(
                    ctx, receiver.0, method_identity,
                    arg_vals, dict_vals, effect_ctx)
            } else {
                panic("C codegen: unknown method identity domain")
            }
            return if is_unit_type(result_ty) { "RING_UNIT" } else { raw }
        },
        none => {}
    }

    // An exact local Ident is a closure slot, never a direct/module symbol.
    // Resolve it before every spelling-based builtin/FFI path.
    let exact_local_callee = match callee {
        HExpr::Ident { name, def_id: some(id), .. } =>
            c_exact_value_slot(ctx, name, id),
        _ => none
    }
    match exact_local_callee {
        some(slot) => {
            for value in dict_vals { arg_vals.push(value) }
            let closure_result = gen_c_closure_call(
                ctx, c_ref_exact(slot), arg_vals, effect_ctx)
            return if is_unit_type(result_ty) {
                "RING_UNIT"
            } else { closure_result }
        },
        none => match callee {
            HExpr::Ident {
                name, def_id: some(id), dict_closure_dicts, ..
            } => match dict_closure_dicts {
                // Final zonk proved a direct declaration/constructor.
                some(_) => {},
                // A DefId-bearing local may never fall through by spelling.
                none => panic(
                    "C codegen: exact local callee '${name}' DefId ${id} has no slot")
            },
            _ => {}
        }
    }


    // Backend/evidence callables have no DefId, but only an explicit
    // name-only registration can classify them as local.  Preserve the
    // resolved-vs-bare key that actually matched and call its slot directly.
    let name_only_local_callee = match callee {
        HExpr::Ident { name, resolved_name, def_id: none, .. } => {
            let call_name = match resolved_name {
                some(rn) => rn,
                none => name
            }
            c_match_name_only_slot(ctx, call_name, name)
        },
        _ => none
    }
    match name_only_local_callee {
        some(matched) => {
            for value in dict_vals { arg_vals.push(value) }
            let closure_result = gen_c_closure_call(
                ctx, c_ref_name_only(matched.slot), arg_vals, effect_ctx)
            return if is_unit_type(result_ty) {
                "RING_UNIT"
            } else { closure_result }
        },
        none => {}
    }

    let raw = match callee {
        HExpr::Ident { name, resolved_name, .. } => {
            let call_name = match resolved_name {
                some(rn) => rn,
                none => name,
            }
            match system_host {
                some(host) => {
                    let extern_key = c_resolve_fn(ctx, call_name)
                    if ctx.ring_callable_names.contains(extern_key) {
                        panic("C codegen: HostImport resolved to Ring callable")
                    }
                    let abi_name = match ctx.extern_abi_names.get(extern_key) {
                        some(value) => value,
                        none => panic(
                            "C codegen: exact HostImport HDecl is absent")
                    }
                    let host_result = gen_c_host_import_call(
                        ctx, host, abi_name, hexpr_type(callee),
                        args, arg_vals, dict_vals)
                    return if is_unit_type(result_ty) {
                        "RING_UNIT"
                    } else { host_result }
                },
                none => {
                    let extern_key = c_resolve_fn(ctx, call_name)
                    if ctx.extern_callable_names.contains(extern_key) {
                        match callee_ref {
                            some(identity) => {
                                if !callee_ref_is_named(identity) {
                                    panic("C codegen: extern CalleeRef is not named")
                                }
                                let abi_name = match
                                        ctx.extern_abi_names.get(extern_key) {
                                    some(value) => value,
                                    none => panic(
                                        "C codegen: exact extern HDecl is absent")
                                }
                                if host_import_fact_for_declaration(
                                        make_named_executable_ref(
                                            callee_ref_named_symbol(identity)),
                                        abi_name, hexpr_type(callee)).is_some() {
                                    panic("C codegen: HostImport call lost its exact marker")
                                }
                            },
                            none => panic(
                                "C codegen: extern call lacks exact CalleeRef")
                        }
                    }
                }
            }
            gen_c_direct_call(
                ctx, call_name, arg_vals, dict_vals,
                c_effect_ctx_source_value(ctx, effect_ctx), callee_ref)
        },
        HExpr::FieldAccess { receiver, field, .. } => {
            let _ = receiver
            let _ = field
            panic("C codegen: method call lost exact MethodCallRef")
        },
        _ => {
            // Closure value call through the uniform {fn_ptr, env} ABI.
            let closure_val = gen_c_expr(ctx, callee)
            let closure_ref = c_ref_computed(
                closure_val, "expression-closure")
            for value in dict_vals { arg_vals.push(value) }
            gen_c_closure_call(ctx, closure_ref, arg_vals, effect_ctx)
        },
    }
    // B-118: Unit-typed call results must be null, never the ABI
    // receiver-return accident.
    if is_unit_type(result_ty) {
        "RING_UNIT"
    } else {
        raw
    }
}

// Ring extern fn name → C runtime name (verbatim port of extern_fn_to_runtime).
fn extern_fn_to_runtime_c(name: Str) -> Str? {
    // Slot bridge calls arrive here only under their unspellable prelude
    // identity.  Map that proven identity back to the raw C ABI symbol.
    match slot_bridge_runtime_name(name) {
        some(runtime_name) => { return some(runtime_name) },
        none => {},
    }
    if name == "panic" { return some("ring_panic") }
    if name == "path_join" { return some("ring_path_join") }
    if name == "path_dirname" { return some("ring_path_dirname") }
    if name == "path_basename" { return some("ring_path_basename") }
    if name == "path_extname" { return some("ring_path_extname") }
    if name == "parse_int" { return some("ring_parse_int") }
    if name == "parse_float" { return some("ring_parse_float") }
    if name == "__ring_raise_fail" { return some("__ring_raise_fail") }
    // B-152: StringBuilder RIIR bridge functions
    if name == "ring_str_as_ptr" { return some("ring_str_as_ptr") }
    if name == "ring_str_from_ptr" { return some("ring_str_from_ptr") }
    if name == "ring_buf_alloc" { return some("ring_buf_alloc") }
    if name == "ring_buf_dealloc" { return some("ring_buf_dealloc") }
    if name == "ring_buf_grow" { return some("ring_buf_grow") }
    if name == "ring_buf_copy_at" { return some("ring_buf_copy_at") }
    if name == "ring_buf_set_byte" { return some("ring_buf_set_byte") }
    if name == "ring_buf_get_byte" { return some("ring_buf_get_byte") }
    if name == "ring_buf_alloc_zeroed" { return some("ring_buf_alloc_zeroed") }
    none
}

// Runtime functions with a void return in the C ABI.
fn is_void_runtime_fn_c(name: Str) -> Bool {
    if name == "ring_catch_pop" { true }
    else if name == "ring_raise" { true }
    else if name == "ring_raw_dealloc" { true }
    else if name == "ring_ptr_copy" { true }
    else if name == "ring_dup" { true }
    else if name == "ring_drop" { true }
    else { false }
}

// Emit a runtime call; returns the value expression (RING_UNIT for void fns).
fn gen_c_runtime_call(mut ctx: CCtx, name: Str, args: List<Str>) -> Str {
    rt_use(ctx, name, args.len())
    if is_void_runtime_fn_c(name) {
        c_emit(ctx, "${name}(${args.join(", ")});")
        "RING_UNIT"
    } else {
        let t = fresh_tmp(ctx)
        c_emit(ctx, "${t} = ${name}(${args.join(", ")});")
        t
    }
}

fn host_import_arity(value: HostImportFact) -> Int {
    match host_import_fact_callable_signature(value) {
        Type::FnType { params, .. } => params.len(),
        _ => panic("C codegen: HostImport signature is not callable")
    }
}

fn gen_c_host_import_call(
    mut ctx: CCtx, host: SystemHostCallableRef,
    raw_abi_name: Str, callable_signature: Type,
    args: List<HExpr>, arg_vals: List<Str>, dict_vals: List<Str>
) -> Str {
    let fact = host_import_fact_for_extern(
        host, raw_abi_name, callable_signature)
    let arity = host_import_arity(fact)
    if args.len() != arity || arg_vals.len() != arity ||
       dict_vals.len() != 0 {
        panic("C codegen: HostImport call arity/evidence differs")
    }
    let target = host_import_fact_native_target(fact)
    let tag = host_import_lowering_tag(
        host_import_fact_lowering(fact))
    if tag == HOST_IMPORT_BOXED_DIRECT {
        return gen_c_runtime_call(ctx, target, arg_vals)
    }
    if tag == HOST_IMPORT_PRINT_VALUE {
        if arity != 1 {
            panic("C codegen: PRINT_VALUE HostImport arity differs")
        }
        let value = arg_vals.get(0).unwrap()
        let value_type = hexpr_type(args.get(0).unwrap())
        let converted = convert_c_to_str(ctx, value, value_type)
        let result = gen_c_runtime_call(ctx, target, [converted])
        if !is_str_type(value_type) {
            c_emit(ctx, "ring_drop(${converted});")
        }
        return result
    }
    if tag == HOST_IMPORT_ASSERT_CONDITION {
        if arity != 2 {
            panic("C codegen: ASSERT_CONDITION HostImport arity differs")
        }
        return gen_c_runtime_call(ctx, target, [
            "RING_COND(${arg_vals.get(0).unwrap()})",
            arg_vals.get(1).unwrap()
        ])
    }
    panic("C codegen: HostImport lowering tag census is incomplete")
}

fn builtin_value_fact_for_callee(
    callee_ref: CalleeRef?
) -> BuiltinValueContractFact? {
    let symbol = match callee_ref {
        some(value) => {
            if !callee_ref_is_named(value) { return none }
            callee_ref_named_symbol(value)
        },
        none => return none
    }
    if symbol_ref_origin_module_key(symbol) != "$builtin" { return none }
    let executable = make_named_executable_ref(symbol)
    let facts = builtin_value_contract_facts()
    if facts.len() != BUILTIN_VALUE_SITE_COUNT {
        panic("C codegen: builtin value manifest census differs")
    }
    let mut found: BuiltinValueContractFact? = none
    let mut index = 0
    while index < facts.len() {
        let fact = facts.get(index).unwrap()
        let fact_symbol = builtin_value_contract_symbol(fact)
        if builtin_value_site_tag(builtin_value_contract_site(fact)) != index ||
           !executable_ref_same(
                builtin_value_contract_executable(fact),
                make_named_executable_ref(fact_symbol)) {
            panic("C codegen: builtin value exact relation differs")
        }
        if symbol_ref_same(symbol, fact_symbol) {
            if found.is_some() || !executable_ref_same(
                    executable, builtin_value_contract_executable(fact)) {
                panic("C codegen: builtin value exact match is not unique")
            }
            found = some(fact)
        }
        index = index + 1
    }
    found
}

fn require_builtin_value_arity(
    fact: BuiltinValueContractFact, args: List<Str>, expected: Int
) {
    let declared = match builtin_value_contract_scheme(fact).ty {
        Type::FnType { params, .. } => params.len(),
        _ => panic("C codegen: builtin value scheme is not callable")
    }
    if declared != expected || args.len() != expected {
        panic("C codegen: builtin value call arity differs")
    }
}

fn validated_builtin_value_physical_data(
    fact: BuiltinValueContractFact, expected_tag: Int,
    expected_data: Str?
) -> Str? {
    let physical = builtin_value_contract_physical(fact)
    if builtin_value_physical_lowering_tag(physical) != expected_tag {
        panic("C codegen: builtin value physical tag differs")
    }
    let actual = builtin_value_physical_lowering_data(physical)
    match (actual, expected_data) {
        (some(value), some(expected)) => {
            if value != expected {
                panic("C codegen: builtin value physical data differs")
            }
            some(value)
        },
        (none, none) => none,
        _ => panic("C codegen: builtin value physical data shape differs")
    }
}

fn builtin_value_runtime_leaf(
    fact: BuiltinValueContractFact, physical_tag: Int,
    expected_name: Str, expected_arity: Int
) -> Str {
    let name = match validated_builtin_value_physical_data(
            fact, physical_tag, some(expected_name)) {
        some(value) => value,
        none => panic("C codegen: builtin value runtime leaf is absent")
    }
    match rt_known_arity(name) {
        some(value) => if value != expected_arity {
            panic("C codegen: builtin value runtime ABI arity differs")
        },
        none => panic("C codegen: builtin value runtime leaf is unknown")
    }
    name
}

fn require_inline_builtin_value_tag(
    fact: BuiltinValueContractFact, expected_tag: Int
) {
    let _ = validated_builtin_value_physical_data(
        fact, expected_tag, none)
}

fn gen_c_builtin_value_call(
    mut ctx: CCtx, arg_vals: List<Str>, dict_vals: List<Str>,
    callee_ref: CalleeRef?
) -> Str? {
    let fact = match builtin_value_fact_for_callee(callee_ref) {
        some(value) => value,
        none => return none
    }
    if dict_vals.len() != 0 {
        panic("C codegen: builtin value call carries dictionary arguments")
    }
    let site = builtin_value_site_tag(builtin_value_contract_site(fact))
    if site == BUILTIN_VALUE_CELL_CONSTRUCTOR {
        require_builtin_value_arity(fact, arg_vals, 1)
        let runtime = builtin_value_runtime_leaf(
            fact, BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME,
            "ring_Cell_new", 1)
        return some(gen_c_runtime_call(ctx, runtime, arg_vals))
    }
    if site == BUILTIN_VALUE_ALLOC {
        require_builtin_value_arity(fact, arg_vals, 1)
        let runtime = builtin_value_runtime_leaf(
            fact, BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME,
            "ring_raw_alloc", 1)
        // Current raw-memory ABI receives the tagged Ring Int count.
        return some(gen_c_runtime_call(ctx, runtime, arg_vals))
    }
    if site == BUILTIN_VALUE_DEALLOC {
        require_builtin_value_arity(fact, arg_vals, 2)
        let runtime = builtin_value_runtime_leaf(
            fact, BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME,
            "ring_raw_dealloc", 2)
        // Current raw-memory ABI receives the tagged Ring Int count.
        return some(gen_c_runtime_call(ctx, runtime, arg_vals))
    }
    if site == BUILTIN_VALUE_PTR_COPY {
        require_builtin_value_arity(fact, arg_vals, 3)
        let runtime = builtin_value_runtime_leaf(
            fact, BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME,
            "ring_ptr_copy", 3)
        // Current raw-memory ABI receives the tagged Ring Int count.
        return some(gen_c_runtime_call(ctx, runtime, arg_vals))
    }
    if site == BUILTIN_VALUE_PTR_FROM_ADDR {
        require_builtin_value_arity(fact, arg_vals, 1)
        require_inline_builtin_value_tag(
            fact, BUILTIN_VALUE_PHYSICAL_PTR_FROM_ADDR)
        let address = arg_vals.get(0).unwrap()
        let result = fresh_tmp(ctx)
        c_emit(ctx,
            "${result} = (void*)(intptr_t)RING_UNTAG(${address});")
        return some(result)
    }
    if site == BUILTIN_VALUE_HASH_COMBINE {
        require_builtin_value_arity(fact, arg_vals, 2)
        let runtime = builtin_value_runtime_leaf(
            fact, BUILTIN_VALUE_PHYSICAL_HASH_COMBINE,
            "ring_hash_combine", 2)
        let left = arg_vals.get(0).unwrap()
        let right = arg_vals.get(1).unwrap()
        rt_use(ctx, runtime, 2)
        let result = fresh_tmp(ctx)
        c_emit(ctx,
            "${result} = RING_INT(${runtime}(RING_UNTAG(${left}), RING_UNTAG(${right})));")
        return some(result)
    }
    if site == BUILTIN_VALUE_STR_IDENTITY {
        require_builtin_value_arity(fact, arg_vals, 1)
        require_inline_builtin_value_tag(
            fact, BUILTIN_VALUE_PHYSICAL_STR_IDENTITY)
        return some(arg_vals.get(0).unwrap())
    }
    if site == BUILTIN_VALUE_BOOL_TO_STR {
        require_builtin_value_arity(fact, arg_vals, 1)
        let runtime = builtin_value_runtime_leaf(
            fact, BUILTIN_VALUE_PHYSICAL_BOOL_TO_STR,
            "ring_bool_to_str", 1)
        let value = arg_vals.get(0).unwrap()
        return some(gen_c_runtime_call(
            ctx, runtime, ["RING_UNTAG(${value})"]))
    }
    if site == BUILTIN_VALUE_LIST_INDEX {
        require_builtin_value_arity(fact, arg_vals, 2)
        let runtime = builtin_value_runtime_leaf(
            fact, BUILTIN_VALUE_PHYSICAL_INDEX, "ring_list_get", 2)
        let receiver = arg_vals.get(0).unwrap()
        let index = arg_vals.get(1).unwrap()
        return some(gen_c_runtime_call(
            ctx, runtime, [receiver, "RING_UNTAG(${index})"]))
    }
    if site == BUILTIN_VALUE_STR_INDEX {
        require_builtin_value_arity(fact, arg_vals, 2)
        let runtime = builtin_value_runtime_leaf(
            fact, BUILTIN_VALUE_PHYSICAL_INDEX, "ring_str_get", 2)
        let receiver = arg_vals.get(0).unwrap()
        let index = arg_vals.get(1).unwrap()
        return some(gen_c_runtime_call(
            ctx, runtime, [receiver, "RING_UNTAG(${index})"]))
    }
    panic("C codegen: builtin value site census is incomplete")
}

// Only the explicit non-HostImport compatibility map may rewrite an extern
// ABI leaf. System-capability externs have already returned through their
// exact HostImport fact; a user extern with the same spelling must remain raw.
fn gen_c_extern_abi_call(mut ctx: CCtx, abi_name: Str, arg_vals: List<Str>) -> Str {
    match extern_fn_to_runtime_c(abi_name) {
        some(rtn) => { return gen_c_runtime_call(ctx, rtn, arg_vals) },
        none => {},
    }
    gen_c_runtime_call(ctx, abi_name, arg_vals)
}

fn gen_c_direct_call(
    mut ctx: CCtx, name: Str, arg_vals: List<Str>,
    dict_vals: List<Str>, effect_ctx_value: Str,
    callee_ref: CalleeRef?
) -> Str {
    match gen_c_builtin_value_call(
            ctx, arg_vals, dict_vals, callee_ref) {
        some(value) => return value,
        none => {}
    }

    let resolved_key = c_resolve_fn(ctx, name)
    let forwards_ctx = c_compiler_extern_forwards_ctx(callee_ref)

    // A project extern-forward resolves directly to the exact Ring target and
    // therefore bypasses ABI lowering. Only a genuine exact extern identity
    // is converted back to its separately stored foreign leaf.
    if ctx.ring_callable_names.contains(resolved_key) == false {
        match ctx.extern_abi_names.get(resolved_key) {
            some(abi_name) => {
                let mut foreign_args: List<Str> = []
                for value in arg_vals { foreign_args.push(value) }
                if forwards_ctx {
                    foreign_args.push(effect_ctx_value)
                }
                return gen_c_extern_abi_call(
                    ctx, abi_name, foreign_args)
            },
            none => {},
        }
        // Raw ABI fallback for non-manifest compiler externs without an HDecl.
        // BuiltinValue leaves were already selected by exact SymbolRef above;
        // exact Ring declarations continue to win over this spelling path.
        match extern_fn_to_runtime_c(name) {
            some(rtn) => {
                if forwards_ctx {
                    panic("C codegen: callback intrinsic census differs")
                }
                return gen_c_runtime_call(ctx, rtn, arg_vals)
            },
            none => {},
        }
    }

    // Ring function lookup (step 8: module-aware resolution, gen_direct_call
    // parity — resolved key first, then bare, then precise cross-module).
    match c_find_function_in_ctx(ctx, resolved_key, name) {
        some(lookup) => {
            let mut call_args: List<Str> = []
            for a in arg_vals { call_args.push(a) }
            for dv in dict_vals { call_args.push(dv) }
            call_args.push(effect_ctx_value)
            let t = fresh_tmp(ctx)
            c_emit(ctx, "${t} = ${lookup.fi.c_name}(${call_args.join(", ")});")
            t
        },
        none => {
            if forwards_ctx {
                panic("C codegen: callback intrinsic census differs")
            }
            gen_c_extern_abi_call(ctx, name, arg_vals)
        },
    }
}

// B-125 Ptr<T> methods are exact builtin intrinsic sites with inline C
// lowering. No runtime ABI symbol or type/name fallback participates.
fn gen_c_ptr_intrinsic(
    mut ctx: CCtx, recv: Str, recv_type: Type, tag: Int, args: List<Str>
) -> Str {
    if tag == BUILTIN_METHOD_PTR_READ {
        let t = fresh_tmp(ctx)
        c_emit(ctx, "${t} = *(void**)${recv};")
        let pointee_ty = match recv_type {
            Type::PtrType { pointee } => pointee,
            _ => Type::AnyType,
        }
        let needs_dup = match pointee_ty {
            Type::IntType => false,
            Type::FloatType => false,
            Type::BoolType => false,
            Type::UnitType => false,
            Type::PtrType { .. } => false,
            _ => true,
        }
        if needs_dup {
            rt_use(ctx, "ring_dup", 1)
            c_emit(ctx, "ring_dup(${t});")
        }
        return t
    }
    if tag == BUILTIN_METHOD_PTR_TAKE {
        let t = fresh_tmp(ctx)
        c_emit(ctx, "${t} = *(void**)${recv};")
        return t
    }
    if tag == BUILTIN_METHOD_PTR_WRITE {
        let v = match args.get(0) { some(a) => a, none => panic("Ptr.write: missing arg") }
        c_emit(ctx, "*(void**)${recv} = ${v};")
        return "RING_UNIT"
    }
    if tag == BUILTIN_METHOD_PTR_OFFSET {
        let i = match args.get(0) { some(a) => a, none => panic("Ptr.offset: missing arg") }
        let t = fresh_tmp(ctx)
        c_emit(ctx, "${t} = (void*)((void**)${recv} + RING_UNTAG(${i}));")
        return t
    }
    if tag == BUILTIN_METHOD_PTR_CAST {
        return recv
    }
    if tag == BUILTIN_METHOD_PTR_ADDR {
        let t = fresh_tmp(ctx)
        c_emit(ctx, "${t} = RING_INT((int64_t)(intptr_t)${recv});")
        return t
    }
    panic("C codegen: unknown Ptr intrinsic site")
}

fn gen_c_method_call(
    mut ctx: CCtx, recv: Str, method_ref: ImplMethodRef,
    args: List<Str>, dict_vals: List<Str>,
    effect_ctx: TypedEffectCtxSource
) -> Str {
    // Ordinary Ring method.  Every runtime-backed 0.1 method has already
    // returned through its exact MethodCallRef above.
    let fi = c_method_info_fn(c_exact_method_info(ctx, method_ref))
    let mut call_args: List<Str> = [recv]
    for a in args { call_args.push(a) }
    for dv in dict_vals { call_args.push(dv) }
    call_args.push(c_effect_ctx_source_value(ctx, effect_ctx))
    if call_args.len() != fi.total_params {
        panic("C method index: concrete call ABI arity differs")
    }
    let t = fresh_tmp(ctx)
    c_emit(ctx, "${t} = ${fi.c_name}(${call_args.join(", ")});")
    t
}

// ============================================================
// Field access — tuple (runtime list), record row type (typeid switch) and
// struct/enum (slot read).  Ports of gen_field_access / gen_record_field_access.
// ============================================================

fn reject_c_error_field_access(kind: HFieldAccessKind) {
    match kind {
        HFieldAccessKind::ErrorRecovery =>
            panic("C codegen: ErrorRecovery field access reached backend"),
        _ => {}
    }
}

fn gen_c_field_access(
    mut ctx: CCtx, receiver: HExpr, field: Str,
    access_kind: HFieldAccessKind, ty: Type
) -> Str {
    reject_c_error_field_access(access_kind)
    let recv_val = gen_c_expr(ctx, receiver)
    let recv_type = hexpr_type(receiver)
    match recv_type {
        Type::TupleType { .. } => {
            let idx = match parse_int(field) {
                some(n) => n,
                none => panic("C codegen: non-numeric tuple field: ${field}"),
            }
            rt_use(ctx, "ring_list_get", 2)
            let t = fresh_tmp(ctx)
            // Tuple field read is a BORROW (B-098); escapes are Clone-wrapped.
            c_emit(ctx, "${t} = ring_list_get(${recv_val}, ${idx});")
            t
        },
        Type::RecordType { .. } => gen_c_record_field_access(ctx, recv_val, field),
        _ => {
            let type_name = match recv_type {
                Type::StructType { name, .. } => name,
                Type::EnumType { name, .. } => name,
                _ => panic("C codegen: field access on non-struct type, field: ${field}"),
            }
            match ctx.struct_types.get(type_name) {
                some(info) => {
                    let mut field_idx = -1
                    for i in 0..info.field_names.len() {
                        if info.field_names[i] == field {
                            field_idx = i
                        }
                    }
                    if field_idx < 0 {
                        panic("C codegen: field '${field}' not found in struct '${type_name}'")
                    }
                    // B-098: a struct field read is a BORROW (no dup); the field
                    // value still belongs to the struct.  If it escapes, the
                    // borrow-inference pass wraps it in HExpr::Clone.
                    let t = fresh_tmp(ctx)
                    c_emit(ctx, "${t} = ((void**)${recv_val})[${field_idx}];")
                    t
                },
                none => panic("C codegen: struct type '${type_name}' not registered"),
            }
        },
    }
}

// Row-type (RecordType) field access: the static type is e.g. {name: Str} but
// the runtime value is a concrete struct.  Read the typeid from the heap
// header at ptr-4 and dispatch over all registered structs that contain the
// requested field (port of gen_record_field_access; candidates sorted by
// struct name — audit #237 determinism discipline).
fn gen_c_record_field_access(mut ctx: CCtx, recv_val: Str, field: Str) -> Str {
    let mut candidates: List<(Str, Int)> = []  // (struct name, field idx)
    let mut sorted = ctx.struct_types.entries()
    sorted.sort_by(compare_by_first)
    for entry in sorted {
        let (sname, sinfo) = entry
        for i in 0..sinfo.field_names.len() {
            if sinfo.field_names[i] == field {
                candidates.push((sname, i))
            }
        }
    }

    if candidates.len() == 0 {
        panic("C codegen: no registered struct has field '${field}' for row-type access")
    }

    let t = fresh_tmp(ctx)

    // Single candidate: skip the typeid dispatch — read the slot directly.
    if candidates.len() == 1 {
        let (_cname, cidx) = candidates[0]
        c_emit(ctx, "${t} = ((void**)${recv_val})[${cidx}];")
        return t
    }

    // Read typeid from the heap header ([rc:u32 | typeid:u32] at ptr-8).
    let tid = fresh_i64(ctx)
    c_emit(ctx, "${tid} = (int64_t)*(uint32_t*)((char*)${recv_val} - 4);")
    let done_lbl = fresh_label(ctx, "row_done")
    for cand in candidates {
        let (cname, cidx) = cand
        let ctid = get_or_assign_c_typeid(ctx, cname)
        c_emit(ctx, "if (${tid} == ${ctid}) { ${t} = ((void**)${recv_val})[${cidx}]; goto ${done_lbl}; }")
    }
    // Default: the type checker guarantees a matching struct (LLVM emits
    // unreachable here); panic instead of UB for robustness.
    let g = c_interned_cstr(ctx, "row-type field access: no matching struct typeid")
    rt_use(ctx, "ring_panic", 1)
    rt_use(ctx, "ring_str_from_cstr", 1)
    c_emit(ctx, "ring_panic(ring_str_from_cstr(${g}));")
    c_raw(ctx, "${done_lbl}:;")
    t
}

// ============================================================
// Struct literal (port of gen_struct_lit).  Layout: N boxed slots, field i at
// ((void**)ptr)[i]; allocated via ring_alloc with the struct's typeid.
// ============================================================

fn gen_c_struct_lit(
    mut ctx: CCtx, name: Str,
    fields: List<HNominalStructFieldInit>, spread: HExpr?,
    constructor: HConstructorPlan?
) -> Str {
    let planned_fields = match constructor {
        some(plan) => {
            if h_constructor_kind(plan) != 2 {
                panic("C codegen: struct literal constructor is not structural")
            }
            h_constructor_fields(plan).len()
        },
        none => panic("C codegen: struct literal lacks constructor plan")
    }
    if planned_fields != fields.len() {
        panic("C codegen: struct literal plan field census differs")
    }
    match spread {
        some(_) => panic(
            "C codegen: struct spread crossed verified ownership lowering"),
        none => {}
    }
    match ctx.struct_types.get(name) {
        some(info) => {
            rt_use(ctx, "ring_alloc", 2)
            let n = info.field_names.len()
            if fields.len() != n {
                panic("C codegen: struct literal field census differs")
            }
            let tid = get_or_assign_c_typeid(ctx, name)
            let t = fresh_tmp(ctx)
            c_emit(ctx, "${t} = ring_alloc((int64_t)(${n} * sizeof(void*)), ${tid});")

            // All fields are explicit after verified ownership lowering.
            for f in fields {
                let val = gen_c_expr(ctx, f.value)
                let mut field_idx = -1
                for i in 0..info.field_names.len() {
                    if info.field_names[i] == f.name {
                        field_idx = i
                    }
                }
                if field_idx < 0 {
                    panic("C codegen: field '${f.name}' not found in struct '${name}'")
                }
                c_emit(ctx, "((void**)${t})[${field_idx}] = ${val};")
            }

            t
        },
        none => panic("C codegen: struct type '${name}' not registered for literal"),
    }
}

// ============================================================
// Named variant construction (port of gen_named_variant_construct).
// Layout: { int64_t tag, void* f0, ..., void* f(max_fields-1) }.
// ============================================================

fn gen_c_variant_construct(
    mut ctx: CCtx, enum_name: Str, variant_name: Str,
    variant_ref: VariantRef,
    fields: List<HStructFieldInit>, spread: HExpr?,
    constructor: HConstructorPlan?
) -> Str {
    match constructor {
        some(plan) => {
            let planned_fields = h_constructor_fields(plan)
            if h_constructor_kind(plan) != 0 ||
               planned_fields.len() != fields.len() {
                panic("C codegen: variant constructor plan differs")
            }
            let mut field_index = 0
            while field_index < fields.len() {
                let planned = planned_fields.get(field_index).unwrap()
                if h_projection_kind(planned) != 1 ||
                   !variant_field_ref_same(
                        h_projection_variant(planned),
                        fields.get(field_index).unwrap().field_ref) {
                    panic("C codegen: variant constructor field differs")
                }
                field_index = field_index + 1
            }
        },
        none => panic("C codegen: variant construct lacks exact plan")
    }
    match spread {
        some(_) => panic(
            "C codegen: variant spread crossed verified ownership lowering"),
        none => {}
    }
    let exact_enum_name = registered_nominal_ref_display_name(
        variant_ref_owner(variant_ref))
    if enum_name != exact_enum_name {
        panic("C codegen: variant construct enum identity differs")
    }
    if variant_ref_same(
            variant_ref, builtin_option_none_variant_ref()) {
        if fields.len() != 0 {
            panic("C codegen: Option.none carries payload fields")
        }
        rt_use(ctx, "ring_Option_none", 0)
        let result = fresh_tmp(ctx)
        c_emit(ctx, "${result} = ring_Option_none();")
        return result
    }

    let mut exact_info: (Str, CEnumInfo, CEnumVariantInfo)? = none
    for enum_entry in ctx.enum_types.entries() {
        let physical_name = enum_entry.0
        let enum_info = enum_entry.1
        for entry in enum_info.variants.entries() {
            let candidate = entry.1
            if variant_ref_same(candidate.variant_ref, variant_ref) {
                if exact_info.is_some() {
                    panic("C codegen: enum registry repeats exact variant")
                }
                if candidate.tag != variant_ref_source_index(variant_ref) {
                    panic("C codegen: exact variant tag differs")
                }
                exact_info = some((physical_name, enum_info, candidate))
            }
        }
    }
    match exact_info {
        some(found) => {
            let (physical_name, enum_info, vi) = found
            rt_use(ctx, "ring_alloc", 2)
            let tid = get_or_assign_c_typeid(ctx, physical_name)
            let t = fresh_tmp(ctx)
            c_emit(ctx, "${t} = ring_alloc((int64_t)(sizeof(int64_t) + ${enum_info.max_fields} * sizeof(void*)), ${tid});")
            c_emit(ctx, "*(int64_t*)${t} = ${vi.tag};")

            // Field placement follows the exact typed field identity;
            // source/display names remain diagnostic payload only.
            for i in 0..fields.len() {
                match fields.get(i) {
                    some(f) => {
                        let val = gen_c_expr(ctx, f.value)
                        if !variant_ref_same(
                                variant_field_ref_variant(f.field_ref),
                                variant_ref) {
                            panic("C codegen: variant field crosses constructor")
                        }
                        let field_idx = variant_field_ref_index(
                            f.field_ref)
                        if field_idx < 0 || field_idx >= vi.field_count {
                            panic("C codegen: variant field index differs")
                        }
                        c_emit(ctx, "((void**)${t})[${field_idx + 1}] = ${val};")
                    },
                    none => {},
                }
            }

            t
        },
        none => panic(
            "C codegen: exact variant '${variant_name}' is absent from enum registry")
    }
}

// ============================================================
// Match expression — the C rendering of gen_match_if_else (the LLVM
// backend's general lowering; its guard-free enum tag-switch is a pure
// optimization with the same semantics for well-formed matches).  Arms are
// tested in source order; a failed pattern test / nested tag check / guard
// jumps to the next arm's label; a matched arm assigns the result temp and
// jumps to the end label.  Fall-through past the last arm = exhaustion panic.
// ============================================================

fn gen_c_match_expr(mut ctx: CCtx, scrutinee: HExpr, arms: List<HMatchArm>) -> Str {
    let scrut = gen_c_expr(ctx, scrutinee)
    ctx.match_counter = ctx.match_counter + 1
    let match_id = ctx.match_counter
    let res = fresh_tmp(ctx)
    let end_lbl = fresh_label(ctx, "mend")

    for arm in arms {
        emit_c_match_arm(ctx, arm, scrut, res, end_lbl)
    }

    // Exhaustion default (gen_match_if_else parity: the checker guarantees
    // exhaustiveness, so this is unreachable in well-typed programs).
    let msg = gen_c_str_lit(ctx, "match exhaustion failure #${match_id}")
    rt_use(ctx, "ring_panic", 1)
    c_emit(ctx, "ring_panic(${msg});")

    c_raw(ctx, "${end_lbl}:;")
    res
}

// One arm: pattern tests (fail → next label) → binds → guard → body.
fn emit_c_match_arm(mut ctx: CCtx, arm: HMatchArm, scrut: Str, res: Str, end_lbl: Str) {
    // Checker parity: every match/catch arm owns a lexical scope.  Clone the
    // inherited bindings before pattern binding / guard / body emission, then
    // restore the outer snapshot before the next arm is generated.
    let saved_named = ctx.named_values
    ctx.named_values = map_clone(saved_named)
    let next_lbl = fresh_label(ctx, "mnext")
    let mut next_used = false
    let exact_bindings = arm.bindings

    match arm.pattern {
        Pattern::Wildcard { .. } => {},
        Pattern::Binding { name: bname, .. } => {
            let bv = c_pattern_local(ctx, bname, exact_bindings)
            c_emit(ctx, "${bv} = ${scrut};")
        },
        Pattern::Literal { value, .. } => {
            emit_c_literal_fail_test(ctx, scrut, value, next_lbl)
            next_used = true
        },
        Pattern::Constructor { name: cname, qualifier, fields, .. } => {
            // Phase 0: outer tag test (unresolvable ctor = unconditional match,
            // mirroring gen_ctor_tag_test's best-effort branch).
            if emit_c_ctor_tag_fail_test(ctx, scrut, cname, qualifier, next_lbl) {
                next_used = true
            }
            // Phase 1: nested constructor tags (only when the enum resolves —
            // struct patterns skip this, LLVM parity).
            match find_c_enum_by_variant(ctx, cname, qualifier) {
                some(_ei) => {
                    if check_c_positional_fields_nested_tags(ctx, scrut, fields, next_lbl) {
                        next_used = true
                    }
                },
                none => {},
            }
            // Phase 2: bind fields.
            bind_c_constructor_fields(
                ctx, scrut, cname, qualifier, fields, exact_bindings)
        },
        Pattern::NamedConstructor { name: cname, qualifier, fields: nfields, .. } => {
            if emit_c_ctor_tag_fail_test(ctx, scrut, cname, qualifier, next_lbl) {
                next_used = true
            }
            match find_c_enum_by_variant(ctx, cname, qualifier) {
                some(ei) => match ei.variants.get(cname) {
                    some(vi) => {
                        if check_c_named_fields_nested_tags(ctx, scrut, vi.field_names, nfields, 1, next_lbl) {
                            next_used = true
                        }
                    },
                    none => {},
                },
                none => match resolve_c_struct_type(ctx, cname) {
                    some(si) => {
                        if check_c_named_fields_nested_tags(ctx, scrut, si.field_names, nfields, 0, next_lbl) {
                            next_used = true
                        }
                    },
                    none => {},
                },
            }
            bind_c_named_constructor_fields(
                ctx, scrut, cname, qualifier, nfields, exact_bindings)
        },
        Pattern::OrPattern { patterns, .. } => {
            // Every successful alternative writes the arm's one shared set of
            // exact slots before entering the common guard/body.
            let body_lbl = fresh_label(ctx, "mor")
            let mut body_used = false
            let nalts = patterns.len()
            if nalts == 0 {
                panic("C codegen: empty or-pattern reached match lowering")
            }
            for k in 0..nalts {
                match patterns.get(k) {
                    some(alt) => {
                        if k == nalts - 1 {
                            if check_c_nested_ctor_tags(
                                    ctx, scrut, alt, next_lbl) {
                                next_used = true
                            }
                            bind_c_root_pattern_after_success(
                                ctx, scrut, alt, exact_bindings)
                        } else {
                            let alt_miss = fresh_label(ctx, "morfail")
                            let tested = check_c_nested_ctor_tags(
                                ctx, scrut, alt, alt_miss)
                            bind_c_root_pattern_after_success(
                                ctx, scrut, alt, exact_bindings)
                            c_emit(ctx, "goto ${body_lbl};")
                            body_used = true
                            if tested {
                                c_raw(ctx, "${alt_miss}:;")
                            }
                        }
                    },
                    none => {},
                }
            }
            if body_used {
                c_raw(ctx, "${body_lbl}:;")
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            rt_use(ctx, "ring_list_get", 2)
            // Phase 1: check every refutable element sub-pattern via
            // check_c_nested_ctor_tags — ctor tags at EVERY depth, literal
            // comparisons, nested tuples.
            // #B-087: a literal element like `(0, s)` must compare, not match-any.
            // #245: a ctor element's INNER sub-patterns must be checked
            // recursively — `(Neg(Lit(0)), _)` previously only verified the
            // one-level Neg tag.
            for j in 0..elements.len() {
                match elements.get(j) {
                    some(elem_pat) => {
                        match elem_pat {
                            Pattern::Binding { .. } => {},
                            Pattern::Wildcard { .. } => {},
                            _ => {
                                let ev = fresh_tmp(ctx)
                                c_emit(ctx, "${ev} = ring_list_get(${scrut}, ${j});")
                                if check_c_nested_ctor_tags(ctx, ev, elem_pat, next_lbl) {
                                    next_used = true
                                }
                            },
                        }
                    },
                    none => {},
                }
            }
            // Phase 2: all checks passed — bind.
            for j2 in 0..elements.len() {
                match elements.get(j2) {
                    some(elem_pat2) => {
                        match elem_pat2 {
                            Pattern::Wildcard { .. } => {},
                            _ => {
                                let fv = fresh_tmp(ctx)
                                c_emit(ctx, "${fv} = ring_list_get(${scrut}, ${j2});")
                                bind_c_nested_pattern(
                                    ctx, fv, elem_pat2, exact_bindings)
                            },
                        }
                    },
                    none => {},
                }
            }
        },
    }

    // Guard (emit_match_arm_body parity): evaluated after binds; a false
    // guard falls through to the next arm.  B-104 D1 Stage 2: a fresh-owned
    // Bool guard box is fully consumed by the untag — drop it once, before
    // the branch, so BOTH edges see it released.
    match arm.guard {
        some(g) => {
            let gv = gen_c_expr(ctx, g)
            let flag = fresh_i64(ctx)
            c_emit(ctx, "${flag} = RING_COND(${gv});")
            if is_fresh_owned_bool_value(g) {
                rt_use(ctx, "ring_drop", 1)
                c_emit(ctx, "ring_drop(${gv});")
            }
            c_emit(ctx, "if (!${flag}) goto ${next_lbl};")
            next_used = true
        },
        none => {},
    }

    // Body.
    let bv = gen_c_expr(ctx, arm.body)
    c_emit(ctx, "${res} = ${bv};")
    c_emit(ctx, "goto ${end_lbl};")
    if next_used {
        c_raw(ctx, "${next_lbl}:;")
    }
    ctx.named_values = saved_named
}

// ============================================================
// Pattern-test helpers (ports of gen_literal_pattern_cond / gen_ctor_tag_test
// / check_nested_ctor_tags / check_*_fields_nested_tags).
// ============================================================

// Fresh str-literal equality flag: allocate the literal, compare, drop the
// literal (#162: gen_str_lit allocates RC=1; drop after comparison).
fn emit_c_str_eq_flag(mut ctx: CCtx, scrut: Str, s: Str) -> Str {
    let lit = gen_c_str_lit(ctx, s)
    rt_use(ctx, "ring_str_eq", 2)
    rt_use(ctx, "ring_drop", 1)
    let flag = fresh_i64(ctx)
    c_emit(ctx, "${flag} = ring_str_eq(${scrut}, ${lit});")
    c_emit(ctx, "ring_drop(${lit});")
    flag
}

fn emit_c_literal_fail_test(mut ctx: CCtx, scrut: Str, value: LiteralValue, fail_lbl: Str) {
    match value {
        LiteralValue::IntVal(n) => {
            c_emit(ctx, "if (RING_UNTAG(${scrut}) != ${n}) goto ${fail_lbl};")
        },
        LiteralValue::BoolVal(b) => {
            let lit = if b { "1" } else { "0" }
            c_emit(ctx, "if (RING_UNTAG(${scrut}) != ${lit}) goto ${fail_lbl};")
        },
        LiteralValue::StrVal(s) => {
            let flag = emit_c_str_eq_flag(ctx, scrut, s)
            c_emit(ctx, "if (!${flag}) goto ${fail_lbl};")
        },
        LiteralValue::FloatVal(f) => {
            // Ordered-equal (LLVM OEQ parity): C == on doubles is false for NaN.
            rt_use(ctx, "ring_unbox_float", 1)
            c_emit(ctx, "if (!(ring_unbox_float(${scrut}) == ${f})) goto ${fail_lbl};")
        },
    }
}

fn emit_c_literal_match_test(mut ctx: CCtx, scrut: Str, value: LiteralValue, match_lbl: Str) {
    match value {
        LiteralValue::IntVal(n) => {
            c_emit(ctx, "if (RING_UNTAG(${scrut}) == ${n}) goto ${match_lbl};")
        },
        LiteralValue::BoolVal(b) => {
            let lit = if b { "1" } else { "0" }
            c_emit(ctx, "if (RING_UNTAG(${scrut}) == ${lit}) goto ${match_lbl};")
        },
        LiteralValue::StrVal(s) => {
            let flag = emit_c_str_eq_flag(ctx, scrut, s)
            c_emit(ctx, "if (${flag}) goto ${match_lbl};")
        },
        LiteralValue::FloatVal(f) => {
            rt_use(ctx, "ring_unbox_float", 1)
            c_emit(ctx, "if (ring_unbox_float(${scrut}) == ${f}) goto ${match_lbl};")
        },
    }
}

// Tag test, fail edge: jump to fail_lbl when the scrutinee's tag differs.
// Returns true when a test was emitted.  An unresolvable variant matches
// unconditionally (no test) — gen_ctor_tag_test best-effort parity.
fn emit_c_ctor_tag_fail_test(mut ctx: CCtx, scrut: Str, cname: Str, qualifier: Str?, fail_lbl: Str) -> Bool {
    match find_c_enum_by_variant(ctx, cname, qualifier) {
        some(ei) => match ei.variants.get(cname) {
            some(vi) => {
                c_emit(ctx, "if (*(int64_t*)${scrut} != ${vi.tag}) goto ${fail_lbl};")
                true
            },
            none => false,
        },
        none => false,
    }
}

// Consume an ignored Bool result (codebase `discard` idiom).
fn discard_c_bool(b: Bool) {
    // intentionally empty
}

// Recursively check the refutable parts of a nested pattern (ctor tags at
// every depth, literal value comparisons (#245), nested tuple elements); a
// mismatch jumps to fail_lbl.  Returns true when any test was emitted.
fn check_c_nested_ctor_tags(mut ctx: CCtx, val: Str, pat: Pattern, fail_lbl: Str) -> Bool {
    match pat {
        Pattern::Constructor { name: cname, qualifier, fields, .. } => {
            match find_c_enum_by_variant(ctx, cname, qualifier) {
                some(ei) => match ei.variants.get(cname) {
                    some(vi) => {
                        c_emit(ctx, "if (*(int64_t*)${val} != ${vi.tag}) goto ${fail_lbl};")
                        for i in 0..fields.len() {
                            match fields.get(i) {
                                some(fp) => {
                                    let fv = fresh_tmp(ctx)
                                    c_emit(ctx, "${fv} = ((void**)${val})[${i + 1}];")
                                    discard_c_bool(check_c_nested_ctor_tags(ctx, fv, fp, fail_lbl))
                                },
                                none => {},
                            }
                        }
                        true
                    },
                    none => false,
                },
                none => false,
            }
        },
        Pattern::NamedConstructor { name: cname, qualifier, fields: nfields, .. } => {
            match find_c_enum_by_variant(ctx, cname, qualifier) {
                some(ei) => match ei.variants.get(cname) {
                    some(vi) => {
                        c_emit(ctx, "if (*(int64_t*)${val} != ${vi.tag}) goto ${fail_lbl};")
                        for i in 0..nfields.len() {
                            match nfields.get(i) {
                                some(nf) => {
                                    let mut field_idx = i
                                    for fi in 0..vi.field_names.len() {
                                        if vi.field_names[fi] == nf.name {
                                            field_idx = fi
                                        }
                                    }
                                    let fv = fresh_tmp(ctx)
                                    c_emit(ctx, "${fv} = ((void**)${val})[${field_idx + 1}];")
                                    discard_c_bool(check_c_nested_ctor_tags(ctx, fv, nf.pattern, fail_lbl))
                                },
                                none => {},
                            }
                        }
                        true
                    },
                    none => false,
                },
                none => match resolve_c_struct_type(ctx, cname) {
                    some(si) => check_c_named_fields_nested_tags(ctx, val, si.field_names, nfields, 0, fail_lbl),
                    none => false,
                },
            }
        },
        Pattern::Literal { value, .. } => {
            // #245: a literal sub-pattern must COMPARE the value (was a no-op,
            // so the first same-tag arm swallowed every value).  RC: the
            // compared value is a borrow (enum field slot / ring_list_get),
            // and emit_c_str_eq_flag drops its own fresh Str literal.
            emit_c_literal_fail_test(ctx, val, value, fail_lbl)
            true
        },
        Pattern::TuplePattern { elements, .. } => {
            // #245: recurse into tuple elements — a ctor field / tuple element
            // may itself be a tuple carrying literals or nested ctors (e.g.
            // `P((0, x))`, `((0, _), y)`).  Elements are borrows (ring_list_get).
            rt_use(ctx, "ring_list_get", 2)
            let mut used = false
            for i in 0..elements.len() {
                match elements.get(i) {
                    some(ep) => {
                        match ep {
                            Pattern::Binding { .. } => {},
                            Pattern::Wildcard { .. } => {},
                            _ => {
                                let ev = fresh_tmp(ctx)
                                c_emit(ctx, "${ev} = ring_list_get(${val}, ${i});")
                                if check_c_nested_ctor_tags(ctx, ev, ep, fail_lbl) {
                                    used = true
                                }
                            },
                        }
                    },
                    none => {},
                }
            }
            used
        },
        _ => false,
    }
}

// Phase-1 nested-tag checking for positional constructor fields (port of
// check_positional_fields_nested_tags).  Returns true when any test emitted.
fn check_c_positional_fields_nested_tags(mut ctx: CCtx, scrut: Str, fields: List<Pattern>, fail_lbl: Str) -> Bool {
    let mut used = false
    for j in 0..fields.len() {
        match fields.get(j) {
            some(fp) => {
                match fp {
                    Pattern::Binding { .. } => {},
                    Pattern::Wildcard { .. } => {},
                    _ => {
                        let fv = fresh_tmp(ctx)
                        c_emit(ctx, "${fv} = ((void**)${scrut})[${j + 1}];")
                        if check_c_nested_ctor_tags(ctx, fv, fp, fail_lbl) {
                            used = true
                        }
                    },
                }
            },
            none => {},
        }
    }
    used
}

// Phase-1 nested-tag checking for named constructor fields (port of
// check_named_fields_nested_tags): resolve each named field's declared slot.
// field_offset is 1 for enum payloads (slot 0 is the tag) and 0 for structs.
fn check_c_named_fields_nested_tags(mut ctx: CCtx, scrut: Str, field_names: List<Str>, named_fields: List<NamedPatternField>, field_offset: Int, fail_lbl: Str) -> Bool {
    let mut used = false
    for j in 0..named_fields.len() {
        match named_fields.get(j) {
            some(nf) => {
                match nf.pattern {
                    Pattern::Binding { .. } => {},
                    Pattern::Wildcard { .. } => {},
                    _ => {
                        let mut fidx = j
                        for fi in 0..field_names.len() {
                            if field_names[fi] == nf.name {
                                fidx = fi
                            }
                        }
                        let fv = fresh_tmp(ctx)
                        c_emit(ctx, "${fv} = ((void**)${scrut})[${fidx + field_offset}];")
                        if check_c_nested_ctor_tags(ctx, fv, nf.pattern, fail_lbl) {
                            used = true
                        }
                    },
                }
            },
            none => {},
        }
    }
    used
}

// ============================================================
// Pattern binding helpers (ports of bind_nested_pattern /
// bind_constructor_fields / bind_named_constructor_fields).
// ============================================================

fn bind_c_root_pattern_after_success(
    mut ctx: CCtx, scrut: Str, pattern: Pattern,
    bindings: List<HPatternBinding>
) {
    match pattern {
        Pattern::Constructor { name, qualifier, fields, .. } =>
            bind_c_constructor_fields(
                ctx, scrut, name, qualifier, fields, bindings),
        Pattern::NamedConstructor { name, qualifier, fields, .. } =>
            bind_c_named_constructor_fields(
                ctx, scrut, name, qualifier, fields, bindings),
        other => bind_c_nested_pattern(ctx, scrut, other, bindings)
    }
}

fn exact_pattern_def_id(
    bindings: List<HPatternBinding>, name: Str
) -> Int {
    let mut result: Int? = none
    for binding in bindings {
        if binding.name == name {
            match result {
                some(existing) => if existing != binding.def_id {
                    panic("C codegen: colliding pattern DefIds for '${name}'")
                },
                none => { result = some(binding.def_id) }
            }
        }
    }
    match result {
        some(id) => id,
        none => panic(
            "C codegen: pattern binding '${name}' has no exact DefId metadata")
    }
}

fn c_pattern_local(
    mut ctx: CCtx, name: Str, bindings: List<HPatternBinding>
) -> Str {
    if name == "_" {
        return fresh_tmp(ctx)
    }
    let def_id = exact_pattern_def_id(bindings, name)
    match c_exact_value_slot(ctx, name, def_id) {
        some(slot) => c_exact_slot_c_name(slot),
        none => c_local_def(ctx, name, some(def_id))
    }
}

fn bind_c_nested_pattern(
    mut ctx: CCtx, val: Str, pat: Pattern,
    bindings: List<HPatternBinding>
) {
    match pat {
        Pattern::Binding { name, .. } => {
            let cv = c_pattern_local(ctx, name, bindings)
            c_emit(ctx, "${cv} = ${val};")
        },
        Pattern::Wildcard { .. } => {},
        Pattern::Literal { .. } => {},
        Pattern::OrPattern { .. } => {},
        Pattern::Constructor { name, qualifier, fields, .. } => {
            match find_c_enum_by_variant(ctx, name, qualifier) {
                some(_ei) => {
                    for i in 0..fields.len() {
                        match fields.get(i) {
                            some(fp) => {
                                let fv = fresh_tmp(ctx)
                                c_emit(ctx, "${fv} = ((void**)${val})[${i + 1}];")
                                bind_c_nested_pattern(ctx, fv, fp, bindings)
                            },
                            none => {},
                        }
                    }
                },
                none => {},
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            // Tuple is a runtime list — element reads via ring_list_get.
            rt_use(ctx, "ring_list_get", 2)
            for i in 0..elements.len() {
                match elements.get(i) {
                    some(ep) => {
                        let ev = fresh_tmp(ctx)
                        c_emit(ctx, "${ev} = ring_list_get(${val}, ${i});")
                        bind_c_nested_pattern(ctx, ev, ep, bindings)
                    },
                    none => {},
                }
            }
        },
        Pattern::NamedConstructor { name, qualifier, fields, .. } => {
            match find_c_enum_by_variant(ctx, name, qualifier) {
                some(ei) => {
                    // Bind by FIELD NAME: the pattern may list fields in any order.
                    let fnames = match ei.variants.get(name) {
                        some(vi) => vi.field_names,
                        none => [],
                    }
                    for i in 0..fields.len() {
                        match fields.get(i) {
                            some(nf) => {
                                let mut field_idx = i
                                for fi in 0..fnames.len() {
                                    if fnames[fi] == nf.name {
                                        field_idx = fi
                                    }
                                }
                                let fv = fresh_tmp(ctx)
                                c_emit(ctx, "${fv} = ((void**)${val})[${field_idx + 1}];")
                                bind_c_nested_pattern(
                                    ctx, fv, nf.pattern, bindings)
                            },
                            none => {},
                        }
                    }
                },
                none => {
                    // Struct pattern fallback: 0-based slots (no tag field).
                    match resolve_c_struct_type(ctx, name) {
                        some(si) => {
                            for i in 0..fields.len() {
                                match fields.get(i) {
                                    some(nf) => {
                                        let mut field_idx = i
                                        for fi in 0..si.field_names.len() {
                                            if si.field_names[fi] == nf.name {
                                                field_idx = fi
                                            }
                                        }
                                        let fv = fresh_tmp(ctx)
                                        c_emit(ctx, "${fv} = ((void**)${val})[${field_idx}];")
                                        bind_c_nested_pattern(
                                            ctx, fv, nf.pattern, bindings)
                                    },
                                    none => {},
                                }
                            }
                        },
                        none => {},
                    }
                },
            }
        },
    }
}

// Bind a positional constructor pattern's fields (tag already verified).
fn bind_c_constructor_fields(
    mut ctx: CCtx, scrut: Str, cname: Str, qualifier: Str?,
    fields: List<Pattern>, bindings: List<HPatternBinding>
) {
    match find_c_enum_by_variant(ctx, cname, qualifier) {
        some(_ei) => {
            for i in 0..fields.len() {
                match fields.get(i) {
                    some(field_pat) => {
                        match field_pat {
                            Pattern::Wildcard { .. } => {},
                            _ => {
                                let fv = fresh_tmp(ctx)
                                c_emit(ctx, "${fv} = ((void**)${scrut})[${i + 1}];")
                                bind_c_nested_pattern(
                                    ctx, fv, field_pat, bindings)
                            },
                        }
                    },
                    none => {},
                }
            }
        },
        none => {
            // Struct pattern fallback: 0-based slots (no tag field at index 0).
            match resolve_c_struct_type(ctx, cname) {
                some(_si) => {
                    for i in 0..fields.len() {
                        match fields.get(i) {
                            some(field_pat) => {
                                match field_pat {
                                    Pattern::Wildcard { .. } => {},
                                    _ => {
                                        let fv = fresh_tmp(ctx)
                                        c_emit(ctx, "${fv} = ((void**)${scrut})[${i}];")
                                        bind_c_nested_pattern(
                                            ctx, fv, field_pat, bindings)
                                    },
                                }
                            },
                            none => {},
                        }
                    }
                },
                none => {},
            }
        },
    }
}

// Bind a named-constructor pattern's fields by field name (tag verified).
fn bind_c_named_constructor_fields(
    mut ctx: CCtx, scrut: Str, cname: Str, qualifier: Str?,
    named_fields: List<NamedPatternField>,
    bindings: List<HPatternBinding>
) {
    match find_c_enum_by_variant(ctx, cname, qualifier) {
        some(ei) => match ei.variants.get(cname) {
            some(vi) => {
                for i in 0..named_fields.len() {
                    match named_fields.get(i) {
                        some(nf) => {
                            let mut field_idx = i
                            for fi in 0..vi.field_names.len() {
                                if vi.field_names[fi] == nf.name {
                                    field_idx = fi
                                }
                            }
                            match nf.pattern {
                                Pattern::Wildcard { .. } => {},
                                _ => {
                                    let fv = fresh_tmp(ctx)
                                    c_emit(ctx, "${fv} = ((void**)${scrut})[${field_idx + 1}];")
                                    bind_c_nested_pattern(
                                        ctx, fv, nf.pattern, bindings)
                                },
                            }
                        },
                        none => {},
                    }
                }
            },
            none => {},
        },
        none => {
            // Struct pattern fallback: 0-based slots.
            match resolve_c_struct_type(ctx, cname) {
                some(si) => {
                    for i in 0..named_fields.len() {
                        match named_fields.get(i) {
                            some(nf) => {
                                let mut field_idx = i
                                for fi in 0..si.field_names.len() {
                                    if si.field_names[fi] == nf.name {
                                        field_idx = fi
                                    }
                                }
                                match nf.pattern {
                                    Pattern::Wildcard { .. } => {},
                                    _ => {
                                        let fv = fresh_tmp(ctx)
                                        c_emit(ctx, "${fv} = ((void**)${scrut})[${field_idx}];")
                                        bind_c_nested_pattern(
                                            ctx, fv, nf.pattern, bindings)
                                    },
                                }
                            },
                            none => {},
                        }
                    }
                },
                none => {},
            }
        },
    }
}

// ============================================================
// Registry lookups (ports of resolve_struct_type / find_enum_by_variant).
// ============================================================

// Pattern identities are canonicalized by the checker.
fn resolve_c_struct_type(ctx: CCtx, name: Str) -> CStructInfo? {
    ctx.struct_types.get(name)
}

// Enum patterns carry an exact canonical qualifier after checking.
fn find_c_enum_by_variant(ctx: CCtx, variant_name: Str, qualifier: Str?) -> CEnumInfo? {
    match qualifier {
        some(q) => {
            match ctx.enum_types.get(q) {
                some(ei) => { return some(ei) },
                none => {},
            }
        },
        none => {},
    }
    none
}

// ============================================================
// Block / if expressions
// ============================================================

fn gen_c_block(mut ctx: CCtx, stmts: List<HStmt>, tail: HExpr?) -> Str {
    for stmt in stmts {
        emit_c_stmt(ctx, stmt)
    }
    match tail {
        some(t) => gen_c_expr(ctx, t),
        none => "RING_UNIT",
    }
}

fn gen_c_if_expr(mut ctx: CCtx, condition: HExpr, then_branch: HExpr, else_branch: HExpr?) -> Str {
    let cond = gen_c_expr(ctx, condition)
    let res = fresh_tmp(ctx)
    c_emit(ctx, "if (RING_COND(${cond})) {")
    ctx.indent = ctx.indent + 1
    let then_val = gen_c_expr(ctx, then_branch)
    c_emit(ctx, "${res} = ${then_val};")
    ctx.indent = ctx.indent - 1
    c_emit(ctx, "} else {")
    ctx.indent = ctx.indent + 1
    let else_val = match else_branch {
        some(eb) => gen_c_expr(ctx, eb),
        none => "RING_UNIT",
    }
    c_emit(ctx, "${res} = ${else_val};")
    ctx.indent = ctx.indent - 1
    c_emit(ctx, "}")
    res
}

// ============================================================
// String interpolation (runtime std::string StringBuilder — same shims the
// LLVM backend uses; B-104 D9 temp drops replicated)
// ============================================================

fn gen_c_string_interp(mut ctx: CCtx, parts: List<HStringInterpPart>) -> Str {
    rt_use(ctx, "ring_sb_new", 0)
    rt_use(ctx, "ring_sb_add", 2)
    rt_use(ctx, "ring_sb_to_str", 1)
    rt_use(ctx, "ring_drop", 1)
    let sb = fresh_tmp(ctx)
    c_emit(ctx, "${sb} = ring_sb_new();")
    for part in parts {
        match part {
            HStringInterpPart::Literal(s) => {
                let sv = gen_c_str_lit(ctx, s)
                c_emit(ctx, "ring_sb_add(${sb}, ${sv});")
                // D9: fresh literal string — drop after the copy-append.
                c_emit(ctx, "ring_drop(${sv});")
            },
            HStringInterpPart::Expression(e) => {
                let v = gen_c_expr(ctx, e)
                let expr_type = hexpr_type(e)
                let sv = convert_c_to_str(ctx, v, expr_type)
                c_emit(ctx, "ring_sb_add(${sb}, ${sv});")
                // D9: drop ONLY codegen-synthesised conversions; Str parts are
                // pass-through (D1-managed — dropping here would double-free).
                if !is_str_type(expr_type) {
                    c_emit(ctx, "ring_drop(${sv});")
                }
            },
        }
    }
    let res = fresh_tmp(ctx)
    c_emit(ctx, "${res} = ring_sb_to_str(${sb});")
    c_emit(ctx, "ring_drop(${sb});")
    res
}

fn convert_c_to_str(mut ctx: CCtx, val: Str, ty: Type) -> Str {
    if is_str_type(ty) {
        val
    } else if is_int_type(ty) {
        rt_use(ctx, "ring_int_to_str", 1)
        let t = fresh_tmp(ctx)
        c_emit(ctx, "${t} = ring_int_to_str(RING_UNTAG(${val}));")
        t
    } else if is_float_type(ty) {
        rt_use(ctx, "ring_unbox_float", 1)
        rt_use(ctx, "ring_float_to_str", 1)
        let t = fresh_tmp(ctx)
        c_emit(ctx, "${t} = ring_float_to_str(ring_unbox_float(${val}));")
        t
    } else if is_bool_type(ty) {
        rt_use(ctx, "ring_bool_to_str", 1)
        let t = fresh_tmp(ctx)
        c_emit(ctx, "${t} = ring_bool_to_str(RING_UNTAG(${val}));")
        t
    } else {
        panic("C codegen: convert_to_str called with unsupported type")
    }
}

// ============================================================
// Tuple literals and indexing. Range/List surface forms are closed before C.
// ============================================================

fn gen_c_tuple_lit(mut ctx: CCtx, elements: List<HExpr>) -> Str {
    rt_use(ctx, "ring_list_new", 0)
    rt_use(ctx, "ring_list_push", 2)
    let t = fresh_tmp(ctx)
    c_emit(ctx, "${t} = ring_list_new();")
    for elem in elements {
        let v = gen_c_expr(ctx, elem)
        c_emit(ctx, "ring_list_push(${t}, ${v});")
    }
    t
}

fn gen_c_index_expr(mut ctx: CCtx, receiver: HExpr, index: HExpr) -> Str {
    let recv_val = gen_c_expr(ctx, receiver)
    let idx_val = gen_c_expr(ctx, index)
    let recv_type = hexpr_type(receiver)
    let type_name = match type_to_builtin_name(recv_type) {
        some(n) => n,
        none => "Unknown",
    }
    let t = fresh_tmp(ctx)
    if type_name == "List" && is_builtin_collection(recv_type) {
        rt_use(ctx, "ring_list_get", 2)
        c_emit(ctx, "${t} = ring_list_get(${recv_val}, RING_UNTAG(${idx_val}));")
    } else if type_name == "Str" {
        rt_use(ctx, "ring_str_get", 2)
        c_emit(ctx, "${t} = ring_str_get(${recv_val}, RING_UNTAG(${idx_val}));")
    } else if type_name == "Map" && is_builtin_collection(recv_type) {
        panic("C codegen: Map IndexExpr must be lowered to map_get_panic")
    } else {
        rt_use(ctx, "ring_list_get", 2)
        c_emit(ctx, "${t} = ring_list_get(${recv_val}, RING_UNTAG(${idx_val}));")
    }
    t
}

// ============================================================
// Statement dispatch
// ============================================================

fn c_is_name_only_dict_def_id(def_id: Int?) -> Bool {
    match def_id {
        some(id) => is_synthetic_dict_def_id(id),
        none => false
    }
}

pub fn emit_c_stmt(mut ctx: CCtx, stmt: HStmt) {
    match stmt {
        HStmt::Let { name, def_id, init, span, .. } => {
            c_line_directive(ctx, span)
            let is_name_only_dict = c_is_name_only_dict_def_id(def_id)
            let val = gen_c_expr(ctx, init)
            let cv = c_local_def(ctx, name, def_id)
            if is_name_only_dict {
                c_register_name_only_value(ctx, name, cv)
            }
            c_emit(ctx, "${cv} = ${val};")
        },
        HStmt::Var { name, def_id, init, span, .. } => {
            c_line_directive(ctx, span)
            let val = gen_c_expr(ctx, init)
            // B-091: closure-written `let mut` is auto-boxed into a shared cell.
            let stored = if is_boxed_def_c(ctx, def_id) { gen_c_cell_alloc(ctx, val) } else { val }
            let cv = c_local_def(ctx, name, def_id)
            c_emit(ctx, "${cv} = ${stored};")
        },
        HStmt::Assign { target, value, span } => {
            c_line_directive(ctx, span)
            emit_c_assign(ctx, target, value)
        },
        HStmt::ExprStmt { expr, span } => {
            c_line_directive(ctx, span)
            let v = gen_c_expr(ctx, expr)
            // Value already materialised (or a pure constant) — discard.
            discard_c(v)
        },
        HStmt::Return { value, span } => {
            c_line_directive(ctx, span)
            // #173: pop enclosing catch frames + drop handler evidence before
            // returning (port of emit_return's cleanup walk; cleanup precedes
            // the value evaluation — LLVM parity).
            emit_c_cleanup_walk(ctx)
            match value {
                some(v) => {
                    let val = gen_c_expr(ctx, v)
                    c_emit(ctx, "return ${val};")
                },
                none => c_emit(ctx, "return RING_UNIT;"),
            }
        },
        HStmt::While { condition, body, span } => {
            c_line_directive(ctx, span)
            emit_c_while(ctx, condition, body)
        },
        HStmt::ForIn { .. } => panic(
            "C codegen: for-in surface statement crossed PreCore"),
        HStmt::Break { .. } => {
            if ctx.in_loop {
                c_emit(ctx, "break;")
            }
        },
        HStmt::Continue { .. } => {
            if ctx.in_loop {
                c_emit(ctx, ctx.loop_continue_stmt)
            }
        },
        HStmt::LetDestructure { bindings, init, span, .. } => {
            c_line_directive(ctx, span)
            emit_c_let_destructure(ctx, bindings, init)
        },
        HStmt::IfLet { pattern, bindings, expr,
                       then_block, else_block, span } => {
            c_line_directive(ctx, span)
            emit_c_if_let(ctx, pattern, bindings,
                expr, then_block, else_block)
        },
        // Perceus RC ops (post-RC HIR input — mandatory from step 2 on).
        HStmt::Drop { name, def_id, slot, place_target, .. } => {
            let value = match place_target {
                some(target) => gen_c_expr(ctx, target),
                none => {
                    let exact = if slot_ref_is_source(slot) {
                        c_exact_value_slot(ctx, name, def_id)
                    } else {
                        c_semantic_value_slot(ctx, slot)
                    }
                    match exact {
                        some(exact_slot) => c_exact_slot_c_name(exact_slot),
                        none => panic(
                            "C codegen: Drop '${name}' has no exact DefId slot")
                    }
                }
            }
            rt_use(ctx, "ring_drop", 1)
            c_emit(ctx, "ring_drop(${value});")
        }
    }
}

// Consume a value expression without emitting an extra operation.
fn discard_c(v: Str) {
    // intentionally empty
}

fn emit_c_assign(mut ctx: CCtx, target: HExpr, value: HExpr) {
    // RHS first (self-reads like `x = x + 1` must see the old value).
    let val = gen_c_expr(ctx, value)
    match target {
        HExpr::Ident { name, resolved_name, def_id, .. } => {
            let boxed = is_boxed_def_c(ctx, def_id)
            let exact_def_id = match def_id {
                some(id) => id,
                none => panic(
                    "C codegen: assignment '${name}' has no exact DefId")
            }
            match c_exact_value_slot(ctx, name, exact_def_id) {
                some(slot) => {
                    let cv = c_exact_slot_c_name(slot)
                    if boxed {
                        c_emit(ctx, "*(void**)${cv} = ${val};")
                    } else {
                        c_emit(ctx, "${cv} = ${val};")
                    }
                },
                none => panic("C codegen: assign to undefined variable '${name}'"),
            }
        },
        HExpr::FieldAccess { receiver, field, access_kind, .. } => {
            reject_c_error_field_access(access_kind)
            // Port of emit_assign's FieldAccess arm: locate the field slot in
            // the struct layout and overwrite it (RC balance is the Perceus
            // pass's responsibility — HIR carries the surrounding dups/drops).
            let recv_val = gen_c_expr(ctx, receiver)
            let recv_type = hexpr_type(receiver)
            let type_name = match recv_type {
                Type::StructType { name, .. } => name,
                _ => panic("C codegen: field assign on non-struct type"),
            }
            match ctx.struct_types.get(type_name) {
                some(info) => {
                    let mut field_idx = -1
                    for i in 0..info.field_names.len() {
                        if info.field_names[i] == field {
                            field_idx = i
                        }
                    }
                    if field_idx < 0 {
                        panic("C codegen: field '${field}' not found in struct '${type_name}'")
                    }
                    c_emit(ctx, "((void**)${recv_val})[${field_idx}] = ${val};")
                },
                none => panic("C codegen: struct type '${type_name}' not registered"),
            }
        },
        _ => panic("C codegen: unsupported assignment target"),
    }
}

// ============================================================
// IfLet — port of emit_if_let: tag test on the scrutinee, then-branch binds
// the pattern's Binding fields, else-branch optional.  Rendered as a plain C
// if/else (no labels needed — both branches fall through to the join).
// ============================================================

fn emit_c_if_let(
    mut ctx: CCtx, pattern: Pattern,
    bindings: List<HPatternBinding>, expr: HExpr,
    then_block: HExpr, else_block: HExpr?
) {
    let scrut = gen_c_expr(ctx, expr)
    let scrut_ty = hexpr_type(expr)
    // Enum name from the scrutinee's type; "Option" fallback for the common
    // if-let-on-Option case (LLVM parity).
    let enum_name = match scrut_ty {
        Type::EnumType { name: en, .. } => en,
        _ => "Option",
    }
    // The pattern and then block share one checker scope.  Else has a separate
    // sibling scope, and the join must see the original outer bindings.
    let saved_named = ctx.named_values
    ctx.named_values = map_clone(saved_named)

    match pattern {
        Pattern::Constructor { name, fields, .. } => {
            let vi_opt = match ctx.enum_types.get(enum_name) {
                some(ei) => ei.variants.get(name),
                none => none,
            }
            match vi_opt {
                some(vi) => {
                    c_emit(ctx, "if (*(int64_t*)${scrut} == ${vi.tag}) {")
                    ctx.indent = ctx.indent + 1
                    bind_c_constructor_fields(ctx, scrut, name,
                        some(enum_name), fields, bindings)
                    discard_c(gen_c_expr(ctx, then_block))
                    ctx.indent = ctx.indent - 1
                    ctx.named_values = saved_named
                    match else_block {
                        some(eb) => {
                            c_emit(ctx, "} else {")
                            ctx.indent = ctx.indent + 1
                            ctx.named_values = map_clone(saved_named)
                            discard_c(gen_c_expr(ctx, eb))
                            ctx.indent = ctx.indent - 1
                            c_emit(ctx, "}")
                        },
                        none => c_emit(ctx, "}"),
                    }
                },
                none => {
                    // Variant/enum not resolvable — execute the then block
                    // unconditionally (LLVM best-effort parity).
                    discard_c(gen_c_expr(ctx, then_block))
                },
            }
        },
        Pattern::NamedConstructor { name: cname, qualifier, fields: nfields, .. } => {
            let else_lbl = fresh_label(ctx, "iflet_else")
            let end_lbl = fresh_label(ctx, "iflet_end")

            // Enum patterns first test their tag. Struct patterns have no tag,
            // so emit_c_ctor_tag_fail_test is a no-op and their 0-based field
            // checks begin immediately.
            discard_c_bool(emit_c_ctor_tag_fail_test(ctx, scrut, cname, qualifier, else_lbl))
            match find_c_enum_by_variant(ctx, cname, qualifier) {
                some(ei) => match ei.variants.get(cname) {
                    some(vi) => {
                        discard_c_bool(check_c_named_fields_nested_tags(ctx, scrut, vi.field_names, nfields, 1, else_lbl))
                    },
                    none => {},
                },
                none => match resolve_c_struct_type(ctx, cname) {
                    some(si) => {
                        discard_c_bool(check_c_named_fields_nested_tags(ctx, scrut, si.field_names, nfields, 0, else_lbl))
                    },
                    none => {},
                },
            }

            // Bind only after every refutable sub-pattern has passed.
            bind_c_named_constructor_fields(
                ctx, scrut, cname, qualifier, nfields, bindings)
            discard_c(gen_c_expr(ctx, then_block))
            c_emit(ctx, "goto ${end_lbl};")
            ctx.named_values = saved_named

            c_raw(ctx, "${else_lbl}:;")
            match else_block {
                some(eb) => {
                    ctx.named_values = map_clone(saved_named)
                    discard_c(gen_c_expr(ctx, eb))
                },
                none => {},
            }
            c_raw(ctx, "${end_lbl}:;")
        },
        Pattern::Binding { name: bname, .. } => {
            // Irrefutable: bind the scrutinee, run then, skip else.
            let bv = c_pattern_local(ctx, bname, bindings)
            c_emit(ctx, "${bv} = ${scrut};")
            discard_c(gen_c_expr(ctx, then_block))
        },
        Pattern::Wildcard { .. } => {
            discard_c(gen_c_expr(ctx, then_block))
        },
        _ => {
            // #176 parity: unrecognized pattern type — compile-time panic
            // rather than silently treating as irrefutable.
            panic("C codegen: unsupported pattern type in if-let")
        },
    }
    ctx.named_values = saved_named
}

// ============================================================
// While loop.  Shape:
//   while (1) { <cond stmts>; flag = RING_COND(c); [drop c]; if (!flag) break; <body> }
// Ring continue → C continue (falls back to the cond re-evaluation, same as
// LLVM's cond_bb target); Ring break → C break.
// ============================================================

fn emit_c_while(mut ctx: CCtx, condition: HExpr, body: HExpr) {
    c_emit(ctx, "while (1) {")
    ctx.indent = ctx.indent + 1
    let cond = gen_c_expr(ctx, condition)
    let flag = fresh_i64(ctx)
    c_emit(ctx, "${flag} = RING_COND(${cond});")
    // B-104 D1 Stage 2: fresh-owned condition box is dropped per evaluation.
    if is_fresh_owned_bool_value(condition) {
        rt_use(ctx, "ring_drop", 1)
        c_emit(ctx, "ring_drop(${cond});")
    }
    c_emit(ctx, "if (!${flag}) break;")

    let saved_cont = ctx.loop_continue_stmt
    let saved_in_loop = ctx.in_loop
    ctx.loop_continue_stmt = "continue;"
    ctx.in_loop = true
    discard_c(gen_c_expr(ctx, body))
    ctx.loop_continue_stmt = saved_cont
    ctx.in_loop = saved_in_loop

    ctx.indent = ctx.indent - 1
    c_emit(ctx, "}")
}

// ============================================================
// LetDestructure — tuple (runtime list) element extraction.
// ============================================================

fn emit_c_let_destructure(mut ctx: CCtx, bindings: List<HLetDestructureBinding>, init: HExpr) {
    let val = gen_c_expr(ctx, init)
    rt_use(ctx, "ring_list_get", 2)
    for i in 0..bindings.len() {
        match bindings.get(i) {
            some(b) => {
                if b.name != "_" {
                    let binding_def_id = match b.def_id {
                        some(id) => id,
                        none => panic(
                            "C codegen: destructure binding has no exact DefId")
                    }
                    let bv = c_local_def(
                        ctx, b.name, some(binding_def_id))
                    c_emit(ctx, "${bv} = ring_list_get(${val}, ${i});")
                }
            },
            none => {},
        }
    }
}
