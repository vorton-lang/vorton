// C-native entry point, declaration emission, module assembly and the
// clang shell-out. Expression/statement emission lives in codegen_c_expr.ring.
//
// The module is a single C11 translation unit built by pure Ring string
// assembly with zero FFI during compilation.  The .c is written to disk and
// compiled by shelling out to `clang -std=c11 -O2 -c` (clang from PATH).
//
// Determinism: every map iteration below goes through sorted keys or fixed
// declaration order (audit #237) — the emitted .c is byte-identical across
// runs.

use types::{Type}
use ast::{Span, UseDecl, UseImport}
use hir::{HExpr, HStmt, HDecl, HParam, HProgram, HStructField, HEnumVariant,
    TraitBound, trait_bound_param_name,
    compare_by_first, hexpr_type,
    scan_trait_method_order, type_contains_extern_handle}
use codegen_c_ctx::{CCtx, CFnInfo, CStructInfo, CEnumInfo, CEnumVariantInfo, CTypedRef,
    CEmitState, new_c_ctx, c_emit, c_raw, c_param, c_param_def,
    c_param_effect_ctx_slot, c_exact_slot_c_name,
    c_local, c_mangle_fn,
    c_mangle_fn_with_prefix, c_sanitize, c_symbol_for_fn_key,
    c_symbol_fragment, c_module_symbol,
    c_register_exact_method, c_exact_method_info,
    c_exact_method_for_owner_slot,
    c_method_info_fn, c_method_info_physical_identity,
    c_mark_exact_method_emitted,
    c_trait_dict_physical_key, c_trait_dict_build_symbol,
    c_effect_ctx_token_symbol,
    c_line_directive,
    rt_use, rt_use_raw,
    get_or_assign_c_typeid, is_runtime_symbol, fresh_tmp,
    fresh_label, c_push_fn, c_pop_fn, c_global_cstr, c_ref_c_name,
    c_enable_identity_ledger, c_identity_ledger_text}
use codegen_c_expr::{gen_c_expr, emit_c_stmt, ensure_c_dict_getter,
    c_exact_mut_symbol_key}
use ir_identity::{
    ImplOwnerRef, ImplMethodRef,
    impl_owner_ref_same,
    impl_owner_ref_target, impl_owner_ref_trait,
    impl_method_ref_owner, impl_method_ref_name,
    impl_method_ref_same, impl_method_ref_callable_slot_index,
    impl_method_ref_stable_key,
    registered_nominal_ref_symbol, symbol_ref_stable_key,
    symbol_ref_canonical_payload,
    variant_ref_source_index,
    builtin_option_some_variant_ref, builtin_option_none_variant_ref}
use ir_inventory::{ExecutableRef,
    executable_ref_is_named, executable_ref_named_symbol,
    effect_ctx_slot, make_exact_static_dict_ref}
use effect_contract::{TypedCallableEffectCtx,
    typed_callable_effect_ctx_binding,
    typed_handled_effect_instance_same}
use legacy_projection::{LegacyEffectCtxToken,
    legacy_effect_ctx_token_ordinal, legacy_effect_ctx_token_instance}
use resolver::{module_prefix}

// ============================================================
// generate_c — main entry point (single-file).
// c_path: the .c text output; o_path: the clang-compiled object file.
// emit_lines: #line directive toggle (--no-c-lines disables).
// ============================================================

fn c_register_effect_ctx_tokens(
    mut ctx: CCtx, tokens: List<LegacyEffectCtxToken>
) {
    let mut index = 0
    for token in tokens {
        let ordinal = legacy_effect_ctx_token_ordinal(token)
        if ordinal != index {
            panic("C codegen: upstream EffectCtx token ordinals are not dense")
        }
        for existing in ctx.effect_ctx_tokens {
            if typed_handled_effect_instance_same(
                    legacy_effect_ctx_token_instance(existing),
                    legacy_effect_ctx_token_instance(token)) {
                panic("C codegen: upstream EffectCtx token instance repeats")
            }
        }
        ctx.effect_ctx_tokens.push(token)
        // Non-const address-taken objects cannot be merged; pointer identity
        // is the runtime's opaque token representation.
        ctx.globals.push(
            "static unsigned char ${c_effect_ctx_token_symbol(ordinal)};")
        index = index + 1
    }
}

pub fn generate_c(
    program: HProgram, effect_ctx_tokens: List<LegacyEffectCtxToken>,
    c_path: Str, o_path: Str, emit_lines: Bool,
    emit_identity_ledger: Bool
) -> Bool {
    if program.derived_impls.len() != 0 {
        panic("C ABI boundary: semantic DerivedImpl carrier was not retired")
    }
    let mut ctx = new_c_ctx(emit_lines)
    c_register_effect_ctx_tokens(ctx, effect_ctx_tokens)
    if emit_identity_ledger { c_enable_identity_ledger(ctx) }

    // B-091: auto-boxed mut-cell def_ids (closure write-through capture).
    for did in program.boxed_vars { ctx.boxed_vars.insert(did) }
    // B-144: extern type names (RC exclusion decisions — field_rc_skip flags
    // consumed by emit_c_drop_functions).
    for en in program.extern_type_names { ctx.extern_types.insert(en) }
    // B-002p1: types with user `impl Drop` (emit_c_drop_functions calls the
    // user drop body before the recursive field drops).
    for dt in program.drop_types { ctx.drop_types.insert(dt) }

    // Trait method slot order + supertrait edges — SHARED hir.ring scan
    // (plan §2.5 #2: single source; no codegen-local trait registry).
    scan_trait_method_order(program.decls, ctx.trait_method_order, ctx.trait_supertraits)

    // Builtin Option has no source HDecl; register only its exact physical
    // layout and the runtime-owned none singleton.
    c_register_builtin_enums(ctx)

    scan_fn_mut_params_c(
        program.decls, program.boxed_vars, ctx.fn_mut_params)

    // First pass: prototypes + registries. Also pre-registers every impl
    // trait dict's build fn (dict_build_fns) so
    // getter routing is declaration-order-independent.
    c_forward_declare(ctx, program.decls)

    // Struct constructors after the whole forward pass: a Ring fn sharing the
    // struct's name wins the ring_<Name> symbol regardless of declaration
    // order (the LLVM backend gets this by emitting struct ctors in pass 2,
    // after every fn was declared).
    c_declare_struct_ctors(ctx, program.decls)

    // Second pass: ordinary function bodies + mechanical impl dict build fns.
    for decl in program.decls {
        emit_c_decl(ctx, decl)
    }

    // Step 7: per-type drop functions (port of emit_drop_functions) + the
    // ring_register_drop statements consumed by the main wrapper below.
    emit_c_drop_functions(ctx)

    // C main() wrapper.
    emit_c_main_wrapper(ctx)

    // Assemble + write + compile.
    c_write_and_compile(ctx, c_path, o_path)
}

// ============================================================
// generate_c_project — multi-module entry point (step 8; mirror of
// generate_llvm_project).  All modules' HIR merged into ONE C translation
// unit (plan §2.1: single .c, B-105 split deferred).  modules: list of
// (module_prefix, post-RC HProgram, use decls) in topo order; entry_prefix
// names the module whose `main` the C main() wrapper calls.
// ============================================================

pub fn generate_c_project(
    modules: List<(Str, HProgram, List<UseDecl>)>, entry_prefix: Str,
    c_path: Str, o_path: Str, emit_lines: Bool,
    extern_forward_bridges: Map<Str, Str>,
    effect_ctx_tokens: List<LegacyEffectCtxToken>
) -> Bool {
    let mut ctx = new_c_ctx(emit_lines)
    c_register_effect_ctx_tokens(ctx, effect_ctx_tokens)
    let mut exact_body_mut_keys: Map<Str, Str> = map_new()
    let mut exact_extern_mut_keys: Map<Str, Str> = map_new()
    for entry in extern_forward_bridges.entries() {
        let (source, target) = entry
        ctx.extern_forward_bridges.insert(c_mangle_fn(source), c_mangle_fn(target))
    }

    // Scan pass over ALL modules (generate_llvm_project parity, same union
    // rules).  #134: boxed_vars is deliberately NOT unioned here — def_ids
    // are minted per-module (fresh InferCtx per check_module), so a global
    // union would mark same-numbered plain locals in other modules; it is
    // set per-module in the body pass below.
    for m in modules {
        let (prefix, program, _uses) = m
        if program.derived_impls.len() != 0 {
            panic("C ABI boundary: project DerivedImpl carrier was not retired")
        }
        // B-144: program-level extern type names (per-module filtered set
        // from compile_phases — union across modules is safe, B-145).
        for en in program.extern_type_names { ctx.extern_types.insert(en) }
        // B-002p1: types with user impl Drop (union across modules).
        for dt in program.drop_types { ctx.drop_types.insert(dt) }
        // Trait method slot order + supertraits (hir.ring single source).
        scan_trait_method_order(program.decls, ctx.trait_method_order, ctx.trait_supertraits)
        scan_fn_mut_params_with_prefix_c(
            program.decls, some(prefix), program.boxed_vars,
            ctx.fn_mut_params, exact_body_mut_keys,
            exact_extern_mut_keys)
    }

    alias_project_extern_forward_mut_params_c(
        extern_forward_bridges, exact_body_mut_keys,
        exact_extern_mut_keys, ctx.fn_mut_params)

    c_register_builtin_enums(ctx)

    // First pass: forward declare all modules' functions with their module
    // prefix (registry keys ring_<prefix>$$_<name>, LLVM key parity; impl
    // methods / traits / enums stay globally bare, also LLVM parity).
    for m in modules {
        let (prefix, program, _uses) = m
        c_forward_declare_with_prefix(ctx, program.decls, some(prefix))
    }

    // Struct ctors after the WHOLE forward pass (fns win ring_<Name>).
    for m in modules {
        let (_prefix, program, _uses) = m
        c_declare_struct_ctors(ctx, program.decls)
    }

    // Second pass: per-module body emission.  module_prefix / boxed_vars /
    // local_names / imports_map are PER-MODULE state (#134).
    for m in modules {
        let (prefix, program, uses) = m
        ctx.module_prefix = some(prefix)
        ctx.boxed_vars = program.boxed_vars
        ctx.local_names = collect_c_module_names(program.decls)
        ctx.imports_map = build_c_imports_map(uses)
        for decl in program.decls {
            emit_c_decl(ctx, decl)
        }
    }

    // Clear module context (LLVM parity: only the prefix is reset; the
    // passes below do registry-keyed lookups, no name resolution).
    ctx.module_prefix = none

    // Drop functions + C main (entry module's main).
    emit_c_drop_functions(ctx)
    emit_c_main_wrapper_common(ctx, c_mangle_fn_with_prefix(entry_prefix, "main"), true)

    c_write_and_compile(ctx, c_path, o_path)
}

// Shared tail of both entry points: assemble the translation unit, write it
// to disk, shell out to clang (audit #242: emit failure must exit non-zero).
fn c_write_and_compile(ctx: CCtx, c_path: Str, o_path: Str) -> Bool {
    // Internal-only H+T output. The runner owns a fresh single-use directory;
    // the compiler accepts no ledger path and performs no racy existence
    // check. Relation validation completes before this sole ledger write.
    let identity_ledger = if ctx.identity_ledger_enabled {
        some(c_identity_ledger_text(ctx))
    } else {
        none
    }
    let text = assemble_c_file(ctx)
    write_file(c_path, text)
    match identity_ledger {
        some(ledger_text) => write_file(
            "${c_path}.identity-ledger", ledger_text),
        none => {}
    }

    let rc = exec_sync("clang", ["-std=c11", "-O2", "-c", c_path, "-o", o_path])
    if rc != 0 {
        eprintln("ring-c: clang failed (exit code ${rc}) compiling ${c_path} — is clang on PATH?")
        false
    } else {
        print("Compiled: ${o_path}")
        true
    }
}

// ============================================================
// Module-mode registries. Historical source: the retired backend's module
// resolver; these helpers are now the C compiler's local implementation.
// ============================================================

// Imported name -> qualified registry key (ring_<module>$$_<name>).
fn build_c_imports_map(uses: List<UseDecl>) -> Map<Str, Str> {
    let mut imap: Map<Str, Str> = map_new()
    for u in uses {
        // resolver::module_prefix is the single source of truth for project
        // registry prefixes (`$` between path segments).
        let module_name = module_prefix(u.path.segments)
        match u.imports {
            UseImport::NamedItems { names } => {
                for ni in names {
                    let local_name = match ni.alias {
                        some(a) => a,
                        none => ni.name,
                    }
                    let qualified = c_mangle_fn_with_prefix(module_name, ni.name)
                    imap.insert(local_name, qualified)
                }
            },
            UseImport::Module => {
                // Whole-module import — not used for function resolution.
            },
        }
    }
    imap
}

// All names a module declares (fed to c_resolve_fn's prefix decision).
// Port of collect_local_names — includes types/consts/traits, NOT just fns:
// the bare-name fallback chain covers unprefixed symbols (struct ctors etc.).
fn collect_c_module_names(decls: List<HDecl>) -> Set<Str> {
    let mut names: Set<Str> = set_new()
    collect_c_module_names_rec(decls, names)
    names
}

fn collect_c_module_names_rec(decls: List<HDecl>, mut names: Set<Str>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, .. } => { names.insert(name) },
            HDecl::Struct { name, .. } => { names.insert(name) },
            HDecl::Enum { name, .. } => { names.insert(name) },
            HDecl::Const { name, .. } => { names.insert(name) },
            HDecl::Trait { name, .. } => { names.insert(name) },
            HDecl::ExternFn { name, .. } => { names.insert(name) },
            HDecl::ExternType { name, .. } => { names.insert(name) },
            HDecl::TypeAlias { name, .. } => { names.insert(name) },
            HDecl::Impl { methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, .. } => {
                            names.insert(mn)
                        },
                        _ => {},
                    }
                }
            },
            HDecl::Effect { name, .. } => { names.insert(name) },
            HDecl::ModBlock { decls: md, .. } => { collect_c_module_names_rec(md, names) },
            HDecl::Test { .. } => {},
        }
    }
}

// ============================================================
// Module assembly
// ============================================================

fn c_preamble() -> List<Str> {
    [
        "/* Generated by `ring build` (C11 backend). Do not edit.             */",
        "/* Every Ring value is represented as a void*. Int/Bool are tagged  */",
        "/* pointers ((v << 1) | 1, B-080); Float/Str/List/... are ring_alloc'd */",
        "/* heap objects with an [rc:u32|typeid:u32] header at ptr-8         */",
        "/* (Perceus RC). Runtime: ring_runtime.cpp (C ABI).                 */",
        "",
        "#include <stdint.h>",
        "#include <stddef.h>",
        "#include <math.h>",
        "#include <setjmp.h>",
        "",
        "typedef struct EffectCtx EffectCtx;",
        "",
        "#define RING_INT(v)    ((void*)(uintptr_t)((((uint64_t)(int64_t)(v)) << 1) | 1u))",
        "#define RING_BOOL(v)   RING_INT(v)",
        "#define RING_TRUE      ((void*)(uintptr_t)3)",
        "#define RING_FALSE     ((void*)(uintptr_t)1)",
        "#define RING_UNIT      ((void*)0)",
        "#define RING_UNTAG(p)  (((int64_t)(intptr_t)(p)) >> 1)",
        "#define RING_COND(p)   ((((int64_t)(intptr_t)(p)) >> 1) & 1)",
        "/* Wrapping integer arithmetic uses unsigned operations because C     */",
        "/* signed overflow is undefined.                                      */",
        "#define RING_IADD(a,b) ((int64_t)((uint64_t)(a) + (uint64_t)(b)))",
        "#define RING_ISUB(a,b) ((int64_t)((uint64_t)(a) - (uint64_t)(b)))",
        "#define RING_IMUL(a,b) ((int64_t)((uint64_t)(a) * (uint64_t)(b)))",
        "#define RING_INEG(a)   ((int64_t)(0u - (uint64_t)(a)))",
        ""
    ]
}

fn assemble_c_file(ctx: CCtx) -> Str {
    let mut out: List<Str> = []
    for l in c_preamble() { out.push(l) }

    out.push("/* ---- runtime prototypes (ring_runtime.cpp C ABI) ---- */")
    let mut rt_names = ctx.rt_protos.keys()
    rt_names.sort()
    for n in rt_names {
        match ctx.rt_protos.get(n) {
            some(p) => out.push(p),
            none => {},
        }
    }
    out.push("")

    if ctx.globals.len() > 0 {
        out.push("/* ---- string constants (explicit-length byte arrays) & const cells ---- */")
        for g in ctx.globals { out.push(g) }
        out.push("")
    }

    if ctx.fn_protos.len() > 0 {
        out.push("/* ---- ring function prototypes ---- */")
        for p in ctx.fn_protos { out.push(p) }
        out.push("")
    }

    for d in ctx.fn_defs {
        out.push(d)
        out.push("")
    }

    out.join("\n")
}

// ============================================================
// Built-in Option physical registry.
// Option: { i64 tag, ptr payload }, typeid 8 (RING_TYPEID_OPTION).
// ring_Option_none is defined by ring_runtime.cpp (B-104 D6 memoised none
// singleton). Option.some and every source enum variant are emitted directly
// from exact typed construction operations, never as C callables.
// ============================================================

fn c_register_builtin_enums(mut ctx: CCtx) {
    rt_use(ctx, "ring_Option_none", 0)

    // Match / if-let and direct construction share this exact tag/layout
    // registry (some=0, none=1).
    let mut option_variants: Map<Str, CEnumVariantInfo> = map_new()
    option_variants.insert("some", CEnumVariantInfo {
        variant_ref: builtin_option_some_variant_ref(),
        tag: 0, field_count: 1,
        field_names: ["value"], field_rc_skip: [false]
    })
    option_variants.insert("none", CEnumVariantInfo {
        variant_ref: builtin_option_none_variant_ref(),
        tag: 1, field_count: 0,
        field_names: [], field_rc_skip: []
    })
    ctx.enum_types.insert("Option", CEnumInfo { variants: option_variants, max_fields: 1 })

    // Pin Option's typeid to the runtime's fixed RING_TYPEID_OPTION (8) so
    // direct construction agrees with the runtime Option makers.
    ctx.type_to_typeid.insert("Option", 8)
}

// ============================================================
// Forward declaration pass — prototypes + registries.
// ============================================================

fn c_forward_declare(mut ctx: CCtx, decls: List<HDecl>) {
    c_forward_declare_with_prefix(ctx, decls, none)
}

// Step 8: prefix-aware forward pass (forward_declare_functions_with_prefix
// parity).  Top-level fns and consts get module-qualified registry keys;
// impl methods, traits, enums, structs and tests stay globally bare.
fn c_forward_declare_with_prefix(mut ctx: CCtx, decls: List<HDecl>, prefix: Str?) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, params, trait_bounds, effect_ctx, .. } => {
                let mangled = match prefix {
                    some(p) => c_mangle_fn_with_prefix(p, name),
                    none => c_mangle_fn(name),
                }
                ctx.ring_callable_names.insert(mangled)
                c_declare_fn(ctx, mangled, params, trait_bounds, effect_ctx)
            },
            HDecl::Impl { owner_ref, trait_name, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, params: mp,
                                    trait_bounds: mtb,
                                    effect_ctx: method_ctx,
                                    impl_method_ref, .. } => {
                            let exact = match impl_method_ref {
                                some(value) => value,
                                none => panic(
                                    "C method index: declaration lacks exact identity")
                            }
                            c_declare_exact_method(
                                ctx, exact, mn, mp, mtb, method_ctx)
                        },
                        _ => {},
                    }
                }
                // Step 5: pre-register the impl trait dict's BUILD FN so the
                // memoised getter (emitted lazily at any use site) routes to
                // the real dict regardless of decl order — the LLVM backend's
                // lazy chain silently falls back to the runtime builtin dict
                // when a use site precedes the impl in decl order.
                match trait_name {
                    some(tn) => {
                        match impl_owner_ref_trait(owner_ref) {
                            some(trait_ref) => if
                                    symbol_ref_canonical_payload(trait_ref) != tn {
                                panic("C method index: impl trait projection differs")
                            },
                            none => panic(
                                "C method index: trait impl lacks exact trait")
                        }
                        let dict_key = c_trait_dict_physical_key(owner_ref)
                        let has_methods = methods.len() > 0
                        if has_methods {
                            match ctx.dict_build_owners.get(dict_key) {
                                some(existing) => if !impl_owner_ref_same(
                                        existing, owner_ref) {
                                    panic("C ABI dict: physical build key has multiple exact owners")
                                },
                                none => ctx.dict_build_owners.insert(
                                    dict_key, owner_ref)
                            }
                            if !ctx.dict_build_fns.contains(dict_key) {
                                ctx.dict_build_fns.insert(dict_key)
                                ctx.fn_protos.push(
                                    "void* ${c_trait_dict_build_symbol(owner_ref)}(void);")
                            }
                        }
                        if tn == "Drop" {
                            let target_key = symbol_ref_stable_key(
                                impl_owner_ref_target(owner_ref))
                            let mut drop_method: ImplMethodRef? = none
                            for method_decl in methods {
                                match method_decl {
                                    HDecl::Fn {
                                        impl_method_ref: some(exact), ..
                                    } => if impl_method_ref_name(exact) == "drop" {
                                        if drop_method.is_some() {
                                            panic("C Drop index: exact drop method repeats")
                                        }
                                        drop_method = some(exact)
                                    },
                                    _ => {}
                                }
                            }
                            let exact_drop = match drop_method {
                                some(value) => value,
                                none => panic("C Drop index: Drop impl has no exact drop method")
                            }
                            match ctx.drop_method_by_nominal_exact.get(target_key) {
                                some(existing) => if !impl_method_ref_same(
                                        existing, exact_drop) {
                                    panic("C Drop index: nominal has multiple exact drop methods")
                                },
                                none => ctx.drop_method_by_nominal_exact.insert(
                                    target_key, exact_drop)
                            }
                        }
                    },
                    none => {},
                }
            },
            HDecl::Trait { .. } => {},
            HDecl::Struct { name, owner_ref, fields, .. } => {
                register_c_nominal_physical(ctx, name,
                    symbol_ref_stable_key(
                        registered_nominal_ref_symbol(owner_ref)))
                let mut fnames: List<Str> = []
                // B-104 D1 rule ① (audit #139): mark fields whose Ring type
                // is (or transitively contains) an extern handle — the drop
                // fn must not ring_drop them (register_struct_info parity).
                let mut frs: List<Bool> = []
                for f in fields {
                    fnames.push(f.name)
                    frs.push(type_contains_extern_handle(f.ty, ctx.extern_types))
                }
                ctx.struct_types.insert(name, CStructInfo { field_names: fnames, field_rc_skip: frs })
                // The ring_<Name> constructor fn is declared AFTER the whole
                // forward pass (c_declare_struct_ctors) — fns win collisions.
            },
            HDecl::Enum { name, owner_ref, variants, .. } => {
                register_c_nominal_physical(ctx, name,
                    symbol_ref_stable_key(
                        registered_nominal_ref_symbol(owner_ref)))
                register_c_enum_info(ctx, name, variants)
            },
            HDecl::Const { name, .. } => {
                // Const = zero-arg lazy getter (same scheme as the LLVM backend).
                // Step 8: module-qualified key in project mode (LLVM parity);
                // the C symbol is the sanitized key.
                let mangled = match prefix {
                    some(p) => c_mangle_fn_with_prefix(p, name),
                    none => c_mangle_fn(name),
                }
                if ctx.functions.contains_key(mangled) == false {
                    let c_name = if is_runtime_symbol(mangled) { "${mangled}__ring" } else { c_symbol_for_fn_key(mangled) }
                    ctx.functions.insert(mangled, CFnInfo {
                        c_name: c_name, total_params: 1,
                        takes_effect_ctx: true })
                    ctx.fn_protos.push(
                        "void* ${c_name}(EffectCtx* effect_ctx);")
                }
            },
            HDecl::Test { .. } => {
                // #215: test block as a zero-arg function.
                let test_name = "ring_test_${ctx.test_fns.len()}"
                ctx.functions.insert(test_name, CFnInfo {
                    c_name: test_name, total_params: 1,
                    takes_effect_ctx: true })
                ctx.fn_protos.push(
                    "void* ${test_name}(EffectCtx* effect_ctx);")
                ctx.test_fns.push(test_name)
            },
            HDecl::ModBlock { decls: md, .. } => {
                // Inline-mod decl names are already module-prefixed by the
                // checker; `::` sanitizes to `__` in c_mangle_fn.
                c_forward_declare_with_prefix(ctx, md, prefix)
            },
            HDecl::Effect { .. } => {},
            HDecl::ExternFn { name, abi_name, .. } => {
                // C externs remain lazily declared at direct call sites, but
                // first-class values need an exact declaration identity and a
                // separate ABI-leaf mapping.
                let extern_key = match prefix {
                    some(p) => c_mangle_fn_with_prefix(p, name),
                    none => c_mangle_fn(name),
                }
                ctx.extern_callable_names.insert(extern_key)
                ctx.extern_abi_names.insert(extern_key, abi_name)
            },
            HDecl::ExternType { .. } => {},
            HDecl::TypeAlias { .. } => {},
        }
    }
}

// ============================================================
// Enum registration. Tags are assigned in declaration order; the value layout
// is { int64_t tag, void* f0, ... } — see codegen_c_ctx::CEnumInfo.
// ============================================================

fn register_c_enum_info(mut ctx: CCtx, name: Str, variants: List<HEnumVariant>) {
    let mut max_fields = 0
    let mut variant_map: Map<Str, CEnumVariantInfo> = map_new()
    let mut tag = 0
    for v in variants {
        if variant_ref_source_index(v.variant_ref) != tag {
            panic("C codegen: enum variant exact index/order differs")
        }
        let fc = v.fields.len()
        if fc > max_fields {
            max_fields = fc
        }
        let fnames = match v.field_names {
            some(names) => names,
            none => {
                let mut ns: List<Str> = []
                for _j in 0..fc { ns.push("") }
                ns
            },
        }
        // B-104 D1 rule ①: extern-containment skip flags per payload field
        // (register_enum_info parity).
        let mut frs: List<Bool> = []
        for ft in v.fields {
            frs.push(type_contains_extern_handle(ft, ctx.extern_types))
        }
        variant_map.insert(v.name, CEnumVariantInfo {
            variant_ref: v.variant_ref,
            tag: tag, field_count: fc,
            field_names: fnames, field_rc_skip: frs
        })
        tag = tag + 1
    }
    ctx.enum_types.insert(name, CEnumInfo { variants: variant_map, max_fields: max_fields })
}

// Struct constructors — declared+defined after the forward pass so that any
// Ring fn with the struct's name keeps the ring_<Name> symbol (LLVM parity:
// emit_struct_constructor's already-declared skip runs in pass 2).
fn c_declare_struct_ctors(mut ctx: CCtx, decls: List<HDecl>) {
    for decl in decls {
        match decl {
            HDecl::Struct { name, fields, .. } => {
                c_emit_struct_ctor(ctx, name, fields)
            },
            HDecl::ModBlock { decls: md, .. } => {
                c_declare_struct_ctors(ctx, md)
            },
            _ => {},
        }
    }
}

fn c_emit_struct_ctor(mut ctx: CCtx, name: Str, fields: List<HStructField>) {
    let key = c_mangle_fn(name)
    if ctx.functions.contains_key(key) {
        // A Ring function already owns this symbol.
        return
    }
    let c_name = if is_runtime_symbol(key) { "${key}__ring" } else { c_symbol_for_fn_key(key) }
    ctx.functions.insert(key, CFnInfo {
        c_name: c_name, total_params: fields.len() + 1,
        takes_effect_ctx: true })
    ctx.ring_callable_names.insert(key)

    rt_use(ctx, "ring_alloc", 2)
    let tid = get_or_assign_c_typeid(ctx, name)
    let mut ps: List<Str> = []
    for i in 0..fields.len() { ps.push("void* a${i}") }
    ps.push("EffectCtx* effect_ctx")
    let params_str = ps.join(", ")
    ctx.fn_protos.push("void* ${c_name}(${params_str});")

    let mut def: List<Str> = []
    def.push("void* ${c_name}(${params_str}) {")
    def.push("    void* p = ring_alloc((int64_t)(${fields.len()} * sizeof(void*)), ${tid});")
    for i in 0..fields.len() {
        def.push("    ((void**)p)[${i}] = a${i};")
    }
    def.push("    return p;")
    def.push("}")
    ctx.fn_defs.push(def.join("\n"))
}

fn c_declare_fn(
    mut ctx: CCtx, mangled: Str, params: List<HParam>,
    trait_bounds: List<TraitBound>,
    effect_ctx: TypedCallableEffectCtx
) {
    let _ = effect_ctx

    // Dedupe (multi-decl re-declaration parity with forward_declare_fn_with_name).
    if ctx.functions.contains_key(mangled) { return }

    // Symbol-collision rename: a Ring fn whose mangled name IS a runtime
    // symbol gets a __ring suffix.
    // All call sites resolve through CFnInfo.c_name, so this is transparent;
    // direct calls to such names route through extern_fn_to_runtime first
    // (runtime shim), matching the LLVM backend's behaviour.
    // Step 8: module-qualified keys carry $$ (LLVM key parity) — the C
    // symbol is the sanitized key (identity for prefix-less names).
    let c_name = if is_runtime_symbol(mangled) {
        "${mangled}__ring"
    } else {
        c_symbol_for_fn_key(mangled)
    }

    let total = params.len() + trait_bounds.len() + 1
    ctx.functions.insert(mangled, CFnInfo {
        c_name: c_name, total_params: total,
        takes_effect_ctx: true })

    // Function-value ABI invariant: wrappers must receive one checker-resolved
    // DictRef per declared bound.
    ctx.fn_trait_bounds.insert(mangled, trait_bounds)

    let mut ps: List<Str> = []
    for _p in params { ps.push("void*") }
    for _b in trait_bounds { ps.push("void*") }
    ps.push("EffectCtx*")
    let params_str = ps.join(", ")
    ctx.fn_protos.push("void* ${c_name}(${params_str});")
}

fn register_c_nominal_physical(
    mut ctx: CCtx, physical_name: Str, exact_key: Str
) {
    match ctx.nominal_exact_by_physical.get(physical_name) {
        some(existing) => if existing != exact_key {
            panic("C nominal index: physical type names multiple exact nominals")
        },
        none => ctx.nominal_exact_by_physical.insert(physical_name, exact_key)
    }
}

fn c_declare_exact_method(
    mut ctx: CCtx, method: ImplMethodRef,
    physical_identity: Str, params: List<HParam>,
    trait_bounds: List<TraitBound>, effect_ctx: TypedCallableEffectCtx
) {
    let _ = effect_ctx
    let expected = "impl-method/${impl_method_ref_stable_key(method)}"
    if physical_identity != expected {
        panic("C method index: HDecl physical identity differs from exact method")
    }
    let total = params.len() + trait_bounds.len() + 1
    let c_name = c_module_symbol("ring-method/${physical_identity}")
    let before = ctx.method_index.len()
    let _ = c_register_exact_method(
        ctx, method, physical_identity, c_name, total)
    if ctx.method_index.len() == before { return }
    let mut ps: List<Str> = []
    for _p in params { ps.push("void*") }
    for _b in trait_bounds { ps.push("void*") }
    ps.push("EffectCtx*")
    ctx.fn_protos.push("void* ${c_name}(${ps.join(", ")});")
}

// ============================================================
// Declaration body emission
// ============================================================

fn emit_c_decl(mut ctx: CCtx, decl: HDecl) {
    match decl {
        HDecl::Fn { name, params, body, trait_bounds,
                    effect_ctx, span, .. } => {
            emit_c_fn_body(ctx, name, params, body, trait_bounds,
                effect_ctx, span)
        },
        HDecl::Impl { owner_ref, trait_name, methods, .. } => {
            for m in methods {
                match m {
                    HDecl::Fn { name: mn, params: mp, body: mb,
                                trait_bounds: mtb,
                                effect_ctx: method_ctx,
                                impl_method_ref, span: msp, .. } => {
                        let exact = match impl_method_ref {
                            some(value) => value,
                            none => panic(
                                "C method index: body lacks exact identity")
                        }
                        emit_c_method_body(
                            ctx, exact, mn, mp, mb, mtb, method_ctx, msp)
                    },
                    _ => {},
                }
            }
            // Core has already elaborated every trait/default/derived method
            // into an ordinary exact HDecl::Fn.  C only assembles the ABI dict.
            match trait_name {
                some(_) => emit_c_trait_dict(ctx, owner_ref, methods),
                none => {},
            }
        },
        HDecl::Struct { .. } => {},
        HDecl::Enum { .. } => {},
        HDecl::Effect { .. } => {},
        HDecl::Test { body, effect_ctx, span, .. } => {
            let test_name = ctx.test_fns[ctx.test_emit_idx]
            ctx.test_emit_idx = ctx.test_emit_idx + 1
            emit_c_zero_arg_fn(ctx, test_name, body, effect_ctx, span)
        },
        HDecl::Trait { .. } => {},
        HDecl::ExternFn { .. } => {},
        HDecl::ExternType { .. } => {},
        HDecl::TypeAlias { .. } => {},
        HDecl::Const { name, init, effect_ctx, span, .. } => {
            emit_c_const_body(ctx, name, init, effect_ctx, span)
        },
        HDecl::ModBlock { decls: md, .. } => {
            for sub in md { emit_c_decl(ctx, sub) }
        },
    }
}

// Per-function emission state bracket (the C analogue of LLVM entry-block
// setup in emit_fn_body).  Returns the saved named_values to restore.
fn begin_c_fn(mut ctx: CCtx, mangled: Str) -> Map<Str, Str> {
    ctx.cur_decls = []
    ctx.cur_body = []
    ctx.used_locals = set_new()
    let saved = ctx.named_values
    ctx.named_values = map_new()
    ctx.name_only_slots = map_new()
    ctx.value_slots_by_def_id = map_new()
    ctx.value_slots_by_slot_key = map_new()
    ctx.in_function = true
    ctx.current_fn_name = mangled
    ctx.indent = 1
    ctx.last_line = -1
    ctx.last_file = ""
    saved
}

fn end_c_fn(mut ctx: CCtx, mangled: Str, params_str: Str, saved: Map<Str, Str>) {
    let mut def: List<Str> = []
    def.push("void* ${mangled}(${params_str}) {")
    for d in ctx.cur_decls { def.push(d) }
    for l in ctx.cur_body { def.push(l) }
    def.push("}")
    ctx.fn_defs.push(def.join("\n"))
    ctx.named_values = saved
    ctx.name_only_slots = map_new()
    ctx.value_slots_by_def_id = map_new()
    ctx.value_slots_by_slot_key = map_new()
    ctx.in_function = false
    ctx.current_fn_name = ""
}

fn emit_c_fn_body(
    mut ctx: CCtx, name: Str, params: List<HParam>, body: HExpr,
    trait_bounds: List<TraitBound>,
    effect_ctx: TypedCallableEffectCtx,
    span: Span
) {
    // Step 8: module-qualified key in project mode (emit_fn_body parity).
    let mangled = match ctx.module_prefix {
        some(prefix) => c_mangle_fn_with_prefix(prefix, name),
        none => c_mangle_fn(name),
    }
    // Definition symbol = CFnInfo.c_name (collision-renamed when needed).
    let c_name = match ctx.functions.get(mangled) {
        some(fi) => fi.c_name,
        none => panic("C codegen: function '${mangled}' not forward-declared"),
    }

    // Ordinary value declarations retain their existing project re-declaration
    // behavior. Impl methods never enter this spelling-keyed path.
    if ctx.emitted_fns.contains(c_name) { return }
    ctx.emitted_fns.insert(c_name)

    emit_c_callable_body(
        ctx, mangled, c_name, params, body, trait_bounds, effect_ctx, span)
}

fn emit_c_method_body(
    mut ctx: CCtx, method: ImplMethodRef, physical_identity: Str,
    params: List<HParam>, body: HExpr, trait_bounds: List<TraitBound>,
    effect_ctx: TypedCallableEffectCtx, span: Span
) {
    let method_info = c_exact_method_info(ctx, method)
    if c_method_info_physical_identity(method_info) != physical_identity {
        panic("C method index: definition physical identity differs")
    }
    let fn_info = c_method_info_fn(method_info)
    if fn_info.total_params != params.len() + trait_bounds.len() + 1 ||
       !fn_info.takes_effect_ctx {
        panic("C method index: definition ABI differs")
    }
    if !c_mark_exact_method_emitted(ctx, method) { return }
    if ctx.emitted_fns.contains(fn_info.c_name) {
        panic("C method index: exact method C symbol collides")
    }
    ctx.emitted_fns.insert(fn_info.c_name)
    emit_c_callable_body(
        ctx, impl_method_ref_stable_key(method), fn_info.c_name,
        params, body, trait_bounds, effect_ctx, span)
}

fn emit_c_callable_body(
    mut ctx: CCtx, registry_key: Str, c_name: Str,
    params: List<HParam>, body: HExpr,
    trait_bounds: List<TraitBound>,
    effect_ctx: TypedCallableEffectCtx, span: Span
) {

    let saved = begin_c_fn(ctx, registry_key)

    // Parameters → C signature (uniform void* boxing, LLVM parity).
    let mut sig_parts: List<Str> = []
    for p in params {
        let cn = c_param_def(ctx, p.name, p.def_id)
        sig_parts.push("void* ${cn}")
    }
    for b in trait_bounds {
        let dn = trait_bound_param_name(b.type_param, b.trait_name)
        let cn = c_param(ctx, dn)
        sig_parts.push("void* ${cn}")
    }
    let ctx_name = c_exact_slot_c_name(c_param_effect_ctx_slot(
        ctx, effect_ctx_slot(typed_callable_effect_ctx_binding(effect_ctx)),
        "__effect_ctx"))
    sig_parts.push("EffectCtx* ${ctx_name}")
    let params_str = sig_parts.join(", ")

    c_line_directive(ctx, span)
    let val = gen_c_expr(ctx, body)
    c_emit(ctx, "return ${val};")

    end_c_fn(ctx, c_name, params_str, saved)
}

fn emit_c_zero_arg_fn(
    mut ctx: CCtx, mangled: Str, body: HExpr,
    effect_ctx: TypedCallableEffectCtx, span: Span
) {
    let saved = begin_c_fn(ctx, mangled)
    let ctx_name = c_exact_slot_c_name(c_param_effect_ctx_slot(
        ctx, effect_ctx_slot(typed_callable_effect_ctx_binding(effect_ctx)),
        "__effect_ctx"))
    c_line_directive(ctx, span)
    let val = gen_c_expr(ctx, body)
    c_emit(ctx, "return ${val};")
    end_c_fn(ctx, mangled, "EffectCtx* ${ctx_name}", saved)
}

// ============================================================
// Const bodies — port of emit_const_body (B-104 D6/D9):
//   Str const  → lazy memoised getter, interned via ring_const_intern
//   enum const → lazy memoised getter, interned via ring_unit_intern
//   other      → per-access re-evaluation (fresh scalar box per call)
// ============================================================

fn emit_c_const_body(
    mut ctx: CCtx, name: Str, init: HExpr,
    effect_ctx: TypedCallableEffectCtx, span: Span
) {
    // Step 8: module-qualified key in project mode (emit_const_body parity).
    let mangled = match ctx.module_prefix {
        some(prefix) => c_mangle_fn_with_prefix(prefix, name),
        none => c_mangle_fn(name),
    }
    // Not forward-declared — skip (LLVM parity).
    if ctx.functions.contains_key(mangled) == false { return }
    let c_name = match ctx.functions.get(mangled) {
        some(fi) => fi.c_name,
        none => mangled,
    }
    let is_str_const = match hexpr_type(init) {
        Type::StrType => true,
        _ => false,
    }
    let is_enum_const = match hexpr_type(init) {
        Type::EnumType { .. } => true,
        _ => false,
    }
    if is_str_const {
        emit_c_memoised_const(
            ctx, c_name, init, effect_ctx, "ring_const_intern", span)
    } else if is_enum_const {
        emit_c_memoised_const(
            ctx, c_name, init, effect_ctx, "ring_unit_intern", span)
    } else {
        emit_c_zero_arg_fn(ctx, c_name, init, effect_ctx, span)
    }
}

fn emit_c_memoised_const(
    mut ctx: CCtx, mangled: Str, init: HExpr,
    effect_ctx: TypedCallableEffectCtx, intern_fn: Str, span: Span
) {
    let g = "__ring_constg_${mangled}"
    ctx.globals.push("static void* ${g} = 0;")
    rt_use(ctx, intern_fn, 1)

    let saved = begin_c_fn(ctx, mangled)
    let ctx_name = c_exact_slot_c_name(c_param_effect_ctx_slot(
        ctx, effect_ctx_slot(typed_callable_effect_ctx_binding(effect_ctx)),
        "__effect_ctx"))
    c_line_directive(ctx, span)
    c_emit(ctx, "if (${g} == 0) {")
    ctx.indent = ctx.indent + 1
    let built = gen_c_expr(ctx, init)
    c_emit(ctx, "${g} = ${intern_fn}(${built});")
    ctx.indent = ctx.indent - 1
    c_emit(ctx, "}")
    c_emit(ctx, "return ${g};")
    end_c_fn(ctx, mangled, "EffectCtx* ${ctx_name}", saved)
}

// ============================================================
// Step 7: per-type drop functions.  For every registered
// struct/enum a `void ring_drop_<T>(void* p)` is generated and registered
// with the RC runtime (drop_table dispatch on the header typeid):
//   * structs: [user `impl Drop` body first (B-002p1)] then per-field
//     ring_drop, skipping extern-handle fields (B-104 D1 rule ①)
//   * enums: [user `impl Drop` body first (B-002p1)] then switch on the tag and
//     ring_drop each payload slot of the live variant (same skip flags)
//   * List/Map keep the runtime's native drop_list/drop_map (fixed typeids
//     4/5, registered by ring_runtime_init — the RingList/RingMapStruct
//     layouts are runtime-private; B-152 P2/P3).  Option keeps the runtime's
//     fixed typeid-8 drop_option path; Result is an ordinary generated enum.
//     Set is an ordinary generated struct; StringBuilder remains an extern
//     type (not in struct_types).
// ABI note: 0.1 user Drop is effect-free. The legacy bridge passes RING_UNIT
// only for any non-self ABI filler so the call matches the complete prototype.
// ============================================================

fn emit_c_drop_functions(mut ctx: CCtx) {
    rt_use(ctx, "ring_drop", 1)

    // ---- user structs (sorted; audit #237 determinism) ----
    let mut struct_names = ctx.struct_types.keys()
    struct_names.sort()
    for sname in struct_names {
        // B-152 P2/P3: runtime-private layouts, native drop at typeid 4/5.
        if sname == "List" { continue }
        if sname == "Map" { continue }
        match ctx.struct_types.get(sname) {
            some(info) => {
                let drop_name = "ring_drop_${c_symbol_fragment(sname)}"
                let mut def: List<Str> = []
                def.push("void ${drop_name}(void* p) {")

                // B-002p1: user `impl Drop` body runs BEFORE the recursive
                // field drops (user cleanup can still read the fields).
                if ctx.drop_types.contains(sname) {
                    let fi = c_exact_user_drop_info(ctx, sname)
                    def.push("    ${fi.c_name}(${c_user_drop_args(ctx, fi.total_params)});")
                }

                for i in 0..info.field_names.len() {
                    let skip = match info.field_rc_skip.get(i) { some(s) => s, none => false }
                    if skip == false {
                        def.push("    ring_drop(((void**)p)[${i}]);")
                    }
                }

                def.push("    (void)p;")
                def.push("}")
                ctx.fn_protos.push("void ${drop_name}(void* p);")
                ctx.fn_defs.push(def.join("\n"))

                let tid = get_or_assign_c_typeid(ctx, sname)
                ctx.drop_registrations.push("ring_register_drop(${tid}, (void*)${drop_name});")
            },
            none => {},
        }
    }

    // ---- user enums (sorted) ----
    let mut enum_names = ctx.enum_types.keys()
    enum_names.sort()
    for ename in enum_names {
        // Option alone uses the runtime's fixed drop_option (typeid 8).
        // Result shares this generated path with every ordinary enum.
        if ename == "Option" { continue }
        match ctx.enum_types.get(ename) {
            some(enum_info) => {
                let drop_name = "ring_drop_${c_symbol_fragment(ename)}"
                let mut def: List<Str> = []
                def.push("void ${drop_name}(void* p) {")

                // The user destructor runs while the complete enum payload is
                // still live, matching the struct drop order above.
                if ctx.drop_types.contains(ename) {
                    let fi = c_exact_user_drop_info(ctx, ename)
                    def.push("    ${fi.c_name}(${c_user_drop_args(ctx, fi.total_params)});")
                }

                let mut variant_keys = enum_info.variants.keys()
                variant_keys.sort()
                if variant_keys.len() > 0 {
                    def.push("    switch (*(int64_t*)p) {")
                    for vname in variant_keys {
                        match enum_info.variants.get(vname) {
                            some(vi) => {
                                def.push("    case ${vi.tag}:")
                                // Payload fields start at slot 1 (slot 0 = tag).
                                for fi in 0..vi.field_count {
                                    let skip = match vi.field_rc_skip.get(fi) { some(s) => s, none => false }
                                    if skip == false {
                                        def.push("        ring_drop(((void**)p)[${fi + 1}]);")
                                    }
                                }
                                def.push("        break;")
                            },
                            none => {},
                        }
                    }
                    def.push("    default:")
                    def.push("        break;")
                    def.push("    }")
                }

                def.push("    (void)p;")
                def.push("}")
                ctx.fn_protos.push("void ${drop_name}(void* p);")
                ctx.fn_defs.push(def.join("\n"))

                let tid = get_or_assign_c_typeid(ctx, ename)
                ctx.drop_registrations.push("ring_register_drop(${tid}, (void*)${drop_name});")
            },
            none => {},
        }
    }

    if ctx.drop_registrations.len() > 0 {
        rt_use(ctx, "ring_register_drop", 2)
    }
}

fn c_exact_user_drop_info(ctx: CCtx, physical_type: Str) -> CFnInfo {
    let nominal_key = match ctx.nominal_exact_by_physical.get(physical_type) {
        some(value) => value,
        none => panic("C Drop index: physical type has no exact nominal")
    }
    let method = match ctx.drop_method_by_nominal_exact.get(nominal_key) {
        some(value) => value,
        none => panic("C Drop index: exact nominal has no Drop method")
    }
    c_method_info_fn(c_exact_method_info(ctx, method))
}

// User Drop receives the value, any dictionary fillers, then empty EffectCtx.
fn c_user_drop_args(
    mut ctx: CCtx, total_params: Int
) -> Str {
    if total_params < 2 {
        panic("C ABI drop: Ring method lacks receiver/context")
    }
    let mut args: List<Str> = ["p"]
    let dict_end = total_params - 1
    for _i in 1..dict_end {
        args.push("RING_UNIT")
    }
    rt_use(ctx, "ring_effect_ctx_empty", 0)
    args.push("ring_effect_ctx_empty()")
    args.join(", ")
}

// ============================================================
// C main() wrapper — parity with emit_c_main_common:
//   ring_runtime_init(argc, argv) → drop registrations (step 7) →
//   ring_main or test functions → return 0.
// ============================================================

fn emit_c_main_wrapper(mut ctx: CCtx) {
    emit_c_main_wrapper_common(ctx, "ring_main", false)
}

// ring_main_key: registry key of the Ring entry fn ("ring_main" single-file,
// ring_<entry_prefix>$$_main in project mode).  warn_no_main mirrors
// emit_c_main_common's project-mode warning.
fn emit_c_main_wrapper_common(mut ctx: CCtx, ring_main_key: Str, warn_no_main: Bool) {
    rt_use_raw(ctx, "ring_runtime_init", "void ring_runtime_init(int argc, char** argv);")
    rt_use(ctx, "ring_effect_ctx_empty", 0)
    let mut lines: List<Str> = []
    lines.push("int main(int argc, char** argv) {")
    lines.push("    ring_runtime_init(argc, argv);")
    // Step 7: register per-type drop functions with the RC runtime BEFORE
    // any Ring code runs.
    for reg in ctx.drop_registrations {
        lines.push("    ${reg}")
    }
    match ctx.functions.get(ring_main_key) {
        some(fi) => {
            lines.push("    ${fi.c_name}(ring_effect_ctx_empty());")
        },
        none => {
            // #215: no fn main — run test functions in declaration order.
            for t in ctx.test_fns {
                lines.push("    ${t}(ring_effect_ctx_empty());")
            }
            if ctx.test_fns.len() == 0 && warn_no_main {
                eprintln("Warning: no main function found in entry module")
            }
        },
    }
    lines.push("    return 0;")
    lines.push("}")
    ctx.fn_defs.push(lines.join("\n"))
}

// A bodyless exact extern has no DefId/boxed-var body authority. Its declared
// mut value type determines whether an internal forward uses the CELL ABI.
fn c_is_value_type(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::BoolType => true,
        Type::StrType => true,
        _ => false,
    }
}

// A defined function's call ABI must match the body ABI emitted by
// `gen_c_ident`: a parameter is a CELL exactly when its DefId is present in
// the module's boxed-var set.  Re-deriving that decision from the parameter
// type misses representation changes such as closure-capture boxing.
fn body_mut_param_flags_c(
    params: List<HParam>, boxed_vars: Set<Int>
) -> List<Bool> {
    let mut flags: List<Bool> = []
    for p in params {
        match p.def_id {
            some(def_id) => flags.push(boxed_vars.contains(def_id)),
            none => flags.push(false)
        }
    }
    flags
}

// Bodyless extern declarations have no parameter DefIds/body slots.  Their
// declared mut-value ABI remains the authority for an exact internal forward.
fn declared_mut_param_flags_c(params: List<HParam>) -> List<Bool> {
    let mut flags: List<Bool> = []
    for p in params {
        if p.name == "self" || !p.is_mutable {
            flags.push(false)
        } else {
            flags.push(c_is_value_type(p.ty))
        }
    }
    flags
}

fn scan_fn_mut_params_c(
    decls: List<HDecl>, boxed_vars: Set<Int>,
    mut fn_mut_params: Map<Str, List<Bool>>
) {
    let mut exact_body_mut_keys: Map<Str, Str> = map_new()
    let mut exact_extern_mut_keys: Map<Str, Str> = map_new()
    scan_fn_mut_params_with_prefix_c(
        decls, none, boxed_vars, fn_mut_params,
        exact_body_mut_keys, exact_extern_mut_keys)
}

fn mut_param_flags_same_c(
    left: List<Bool>, right: List<Bool>
) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        match (left.get(index), right.get(index)) {
            (some(a), some(b)) => if a != b { return false },
            _ => return false
        }
        index = index + 1
    }
    true
}

fn register_exact_mut_flags_c(
    mut fn_mut_params: Map<Str, List<Bool>>,
    exact_key: Str, flags: List<Bool>
) {
    match fn_mut_params.get(exact_key) {
        some(existing) => {
            if !mut_param_flags_same_c(existing, flags) {
                panic("C mut ABI: duplicate exact executable has different arity/flags")
            }
            // Same exact declaration may be carried idempotently (for
            // example the shared prelude). Validate, but never overwrite.
        },
        none => fn_mut_params.insert(exact_key, flags)
    }
}

fn register_exact_mut_physical_key_c(
    mut physical_keys: Map<Str, Str>, physical_key: Str, exact_key: Str
) {
    match physical_keys.get(physical_key) {
        some(existing) => if existing != exact_key {
            panic("C mut ABI: one physical callable names multiple exact executables")
        },
        none => physical_keys.insert(physical_key, exact_key)
    }
}

fn insert_exact_body_mut_params_c(
    mut fn_mut_params: Map<Str, List<Bool>>,
    executable: ExecutableRef, params: List<HParam>,
    boxed_vars: Set<Int>, physical_key: Str,
    mut exact_body_mut_keys: Map<Str, Str>
) {
    if !executable_ref_is_named(executable) {
        panic("C mut ABI: defined HDecl executable is not named")
    }
    let exact_key = c_exact_mut_symbol_key(
        executable_ref_named_symbol(executable))
    register_exact_mut_flags_c(fn_mut_params, exact_key,
        body_mut_param_flags_c(params, boxed_vars))
    register_exact_mut_physical_key_c(
        exact_body_mut_keys, physical_key, exact_key)
}

fn insert_exact_declared_mut_params_c(
    mut fn_mut_params: Map<Str, List<Bool>>,
    executable: ExecutableRef, params: List<HParam>, physical_key: Str,
    mut exact_extern_mut_keys: Map<Str, Str>
) {
    if !executable_ref_is_named(executable) {
        panic("C mut ABI: extern HDecl executable is not named")
    }
    let exact_key = c_exact_mut_symbol_key(
        executable_ref_named_symbol(executable))
    register_exact_mut_flags_c(
        fn_mut_params, exact_key, declared_mut_param_flags_c(params))
    register_exact_mut_physical_key_c(
        exact_extern_mut_keys, physical_key, exact_key)
}

fn require_exact_mut_physical_key_c(
    keys: Map<Str, Str>, physical_key: Str, role: Str
) -> Str {
    match keys.get(physical_key) {
        some(exact_key) => exact_key,
        none => panic(
            "C mut ABI: extern-forward ${role} has no exact HDecl")
    }
}

fn require_exact_mut_flags_c(
    flags: Map<Str, List<Bool>>, exact_key: Str, role: Str
) -> List<Bool> {
    match flags.get(exact_key) {
        some(values) => values,
        none => panic(
            "C mut ABI: extern-forward ${role} has no exact flags")
    }
}

fn alias_project_extern_forward_mut_params_c(
    extern_forward_bridges: Map<Str, Str>,
    exact_body_mut_keys: Map<Str, Str>,
    exact_extern_mut_keys: Map<Str, Str>,
    mut fn_mut_params: Map<Str, List<Bool>>
) {
    for entry in extern_forward_bridges.entries() {
        let (source, target) = entry
        let source_exact = require_exact_mut_physical_key_c(
            exact_extern_mut_keys, c_mangle_fn(source), "source")
        let target_exact = require_exact_mut_physical_key_c(
            exact_body_mut_keys, c_mangle_fn(target), "target")
        if source_exact == target_exact {
            panic("C mut ABI: extern-forward aliases one exact declaration to itself")
        }
        let source_flags = require_exact_mut_flags_c(
            fn_mut_params, source_exact, "source")
        let target_flags = require_exact_mut_flags_c(
            fn_mut_params, target_exact, "target")
        if source_flags.len() != target_flags.len() {
            panic("C mut ABI: extern-forward source/target arity differs")
        }
        // This deliberate replacement is the project bridge cutover: exact
        // calls to the declaration now share the provider body's CELL ABI.
        // Genuine externs are absent from the bridge map and keep their
        // declaration-derived flags registered above.
        fn_mut_params.insert(source_exact, target_flags)
    }
}

fn scan_fn_mut_params_with_prefix_c(
    decls: List<HDecl>, prefix: Str?, boxed_vars: Set<Int>,
    mut fn_mut_params: Map<Str, List<Bool>>,
    mut exact_body_mut_keys: Map<Str, Str>,
    mut exact_extern_mut_keys: Map<Str, Str>
) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, executable_ref, params, .. } => {
                let key = match prefix {
                    some(p) => c_mangle_fn_with_prefix(p, name),
                    none => name,
                }
                fn_mut_params.insert(
                    key, body_mut_param_flags_c(params, boxed_vars))
                insert_exact_body_mut_params_c(
                    fn_mut_params, executable_ref, params, boxed_vars,
                    key, exact_body_mut_keys)
            },
            HDecl::ExternFn { name, executable_ref, params, .. } => {
                let key = match prefix {
                    some(p) => c_mangle_fn_with_prefix(p, name),
                    none => c_mangle_fn(name)
                }
                insert_exact_declared_mut_params_c(
                    fn_mut_params, executable_ref, params, key,
                    exact_extern_mut_keys)
            },
            HDecl::Impl { methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn {
                            impl_method_ref, params: mp, ..
                        } => {
                            let exact = match impl_method_ref {
                                some(value) => value,
                                none => panic(
                                    "C mut ABI: impl method lacks exact identity")
                            }
                            register_exact_mut_flags_c(
                                fn_mut_params,
                                impl_method_ref_stable_key(exact),
                                body_mut_param_flags_c(mp, boxed_vars))
                        },
                        _ => {},
                    }
                }
            },
            HDecl::ModBlock { decls: md, .. } => {
                scan_fn_mut_params_with_prefix_c(
                    md, prefix, boxed_vars, fn_mut_params,
                    exact_body_mut_keys, exact_extern_mut_keys)
            },
            _ => {},
        }
    }
}

// ============================================================
// Mechanical trait dict emission for exact ordinary impl methods.
// Dict layout { i64 method_count, ptr m0, ... } typeid 16 (DICT_STATIC);
// each slot is a {thunk, env} closure (typeid 7).
// ============================================================

fn emit_c_trait_dict(
    mut ctx: CCtx, owner: ImplOwnerRef, methods: List<HDecl>
) {
    let dict_key = c_trait_dict_physical_key(owner)

    let mut method_order: List<ImplMethodRef> = []
    for m in methods {
        match m {
            HDecl::Fn { impl_method_ref, .. } => {
                let exact = match impl_method_ref {
                    some(value) => value,
                    none => panic(
                        "C ABI dict: ordinary impl method lacks exact identity")
                }
                if impl_method_ref_callable_slot_index(exact) !=
                        method_order.len() {
                    panic("C ABI dict: exact method slot order differs")
                }
                if !impl_owner_ref_same(
                        impl_method_ref_owner(exact), owner) {
                    panic("C ABI dict: exact method owner differs")
                }
                let indexed = c_exact_method_for_owner_slot(
                    ctx, owner, method_order.len())
                let indexed_fn = c_method_info_fn(indexed)
                let exact_fn = c_method_info_fn(c_exact_method_info(ctx, exact))
                if indexed_fn.c_name != exact_fn.c_name ||
                   indexed_fn.total_params != exact_fn.total_params {
                    panic("C ABI dict: owner slot/index relation differs")
                }
                method_order.push(exact)
            },
            _ => panic("C ABI dict: impl method carrier is not a function"),
        }
    }
    let method_count = method_order.len()
    if method_count == 0 { return }

    let build_fn_name = c_trait_dict_build_symbol(owner)
    if ctx.emitted_fns.contains(build_fn_name) { return }
    ctx.emitted_fns.insert(build_fn_name)
    // Defensive ABI registration if the forward pass did not predeclare it.
    if ctx.dict_build_fns.contains(dict_key) == false {
        ctx.dict_build_fns.insert(dict_key)
        ctx.fn_protos.push("void* ${build_fn_name}(void);")
    }

    let saved = c_push_fn(ctx, build_fn_name)
    rt_use(ctx, "ring_alloc", 2)
    let dict = fresh_tmp(ctx)
    c_emit(ctx, "${dict} = ring_alloc((int64_t)(sizeof(int64_t) + ${method_count} * sizeof(void*)), 16);")
    c_emit(ctx, "*(int64_t*)${dict} = ${method_count};")
    for i in 0..method_count {
        match method_order.get(i) {
            some(method) => {
                emit_c_dict_method_slot(ctx, method, dict, i)
            },
            none => {},
        }
    }
    c_emit(ctx, "return ${dict};")
    c_pop_fn(ctx, build_fn_name, "void", saved)

    // Memoised getter (routes through the build fn — dict_build_fns entry).
    let _g = ensure_c_dict_getter(
        ctx, make_exact_static_dict_ref(owner))
}

fn emit_c_dict_method_slot(
    mut ctx: CCtx, method: ImplMethodRef,
    dict_var: Str, slot_idx: Int
) {
    let fi = c_method_info_fn(c_exact_method_info(ctx, method))
    // Direct-ABI impl method behind an env-dropping thunk (B-092).
    let thunk = ensure_c_dict_method_thunk(ctx, fi.c_name, fi.total_params)
    let cls = fresh_tmp(ctx)
    c_emit(ctx, "${cls} = ring_alloc((int64_t)(2 * sizeof(void*)), 7);")
    c_emit(ctx, "((void**)${cls})[0] = (void*)${thunk};")
    c_emit(ctx, "((void**)${cls})[1] = RING_UNIT;")
    c_emit(ctx, "((void**)${dict_var})[${slot_idx + 1}] = ${cls};")
}

// Env-dropping thunk forwards visible/dictionary arguments then EffectCtx.
fn ensure_c_dict_method_thunk(mut ctx: CCtx, method_c_name: Str, method_arity: Int) -> Str {
    let thunk_name = "${method_c_name}__dictthunk"
    if ctx.emitted_fns.contains(thunk_name) { return thunk_name }
    ctx.emitted_fns.insert(thunk_name)
    if method_arity < 1 {
        panic("C ABI dict: Ring method lacks EffectCtx")
    }
    let mut sig_parts: List<Str> = ["void* env"]
    let mut fwd: List<Str> = []
    let forwarded_arity = method_arity - 1
    for i in 0..forwarded_arity {
        sig_parts.push("void* p${i}")
        fwd.push("p${i}")
    }
    sig_parts.push("EffectCtx* effect_ctx")
    fwd.push("effect_ctx")
    ctx.fn_protos.push("void* ${thunk_name}(${sig_parts.join(", ")});")
    let mut def: List<Str> = []
    def.push("void* ${thunk_name}(${sig_parts.join(", ")}) {")
    def.push("    return ${method_c_name}(${fwd.join(", ")});")
    def.push("}")
    ctx.fn_defs.push(def.join("\n"))
    thunk_name
}

// All trait-default and derived executable semantics are ordinary Core-generated
// HDecl::Fn bodies before this mechanical C ABI boundary.
