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

use types::{Type, Effect, EffectRow, effect_kind_name}
use ast::{Span, UseDecl, UseImport}
use hir::{HExpr, HStmt, HDecl, HParam, HProgram, HStructField, HEnumVariant,
    HEffectOp, TraitBound, evidence_param_name, trait_bound_param_name,
    variant_ctor_name, compare_by_first, hexpr_type, trait_dict_name,
    scan_trait_method_order, type_contains_extern_handle}
use codegen_c_ctx::{CCtx, CFnInfo, CStructInfo, CEnumInfo, CEnumVariantInfo, CTypedRef,
    CEmitState, new_c_ctx, c_emit, c_raw, c_param, c_param_def,
    c_local, c_mangle_fn,
    c_mangle_fn_with_prefix, c_mangle_method, c_sanitize, c_symbol_for_fn_key, c_symbol_fragment,
    c_line_directive,
    rt_use, rt_use_raw,
    get_or_assign_c_typeid, is_runtime_symbol, fresh_tmp,
    fresh_label, c_push_fn, c_pop_fn, c_global_cstr, c_ref_c_name,
    c_enable_identity_ledger, c_identity_ledger_text}
use codegen_c_expr::{gen_c_expr, emit_c_stmt, ensure_c_dict_getter}
use effect_analysis::{extract_effect_names, collect_fn_callees}
use ir_identity::{
    symbol_ref_canonical_payload,
    impl_method_ref_callable_slot_index
}
use resolver::{module_prefix}

// ============================================================
// generate_c — main entry point (single-file).
// c_path: the .c text output; o_path: the clang-compiled object file.
// emit_lines: #line directive toggle (--no-c-lines disables).
// ============================================================

pub fn generate_c(
    program: HProgram, c_path: Str, o_path: Str, emit_lines: Bool,
    emit_identity_ledger: Bool
) -> Bool {
    if program.derived_impls.len() != 0 {
        panic("C ABI boundary: semantic DerivedImpl carrier was not retired")
    }
    let mut ctx = new_c_ctx(emit_lines)
    if emit_identity_ledger { c_enable_identity_ledger(ctx) }

    // B-091: auto-boxed mut-cell def_ids (closure write-through capture).
    for did in program.boxed_vars { ctx.boxed_vars.insert(did) }
    // B-144: extern type names (RC exclusion decisions — field_rc_skip flags
    // consumed by emit_c_drop_functions).
    for en in program.extern_type_names { ctx.extern_types.insert(en) }
    // B-002p1: types with user `impl Drop` (emit_c_drop_functions calls the
    // user drop body before the recursive field drops).
    for dt in program.drop_types { ctx.drop_types.insert(dt) }

    // B-104 D4: static dict singleton definitions (dict_lower) — the memoised
    // getters build wrapped instances from these.
    for sd in program.static_dicts { ctx.static_dict_defs.insert(sd.name, sd) }

    // Trait method slot order + supertrait edges — SHARED hir.ring scan
    // (plan §2.5 #2: single source; no codegen-local trait registry).
    scan_trait_method_order(program.decls, ctx.trait_method_order, ctx.trait_supertraits)

    // Built-in enums (Option/Result ctors — Option layout {i64 tag, ptr payload}).
    c_register_builtin_enums(ctx)

    // Effect scan + transitive closure (B-089 G-b) — determines evidence
    // param counts, which are part of every C prototype.
    scan_fn_effects_c(program.decls, ctx.local_fn_effects)
    scan_fn_mut_params_c(program.decls, ctx.fn_mut_params)
    compute_transitive_effect_closure_c(program.decls, ctx.local_fn_effects)

    // Step 6: effect op declarations (slot-order contract).
    register_effect_ops_c(program.decls, ctx.effect_ops)

    // First pass: prototypes + registries (enum variant ctors are declared
    // AND defined here — their bodies depend on nothing but the registries).
    // Also pre-registers every impl trait dict's build fn (dict_build_fns) so
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
    extern_forward_bridges: Map<Str, Str>
) -> Bool {
    let mut ctx = new_c_ctx(emit_lines)
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
        // B-104 D4: static dict singletons — instance names deterministically
        // encode their structure, same-name entries are identical (dedupe).
        for sd in program.static_dicts { ctx.static_dict_defs.insert(sd.name, sd) }
        // Trait method slot order + supertraits (hir.ring single source).
        scan_trait_method_order(program.decls, ctx.trait_method_order, ctx.trait_supertraits)
        scan_fn_effects_with_prefix_c(program.decls, some(prefix), ctx.local_fn_effects)
        scan_fn_mut_params_with_prefix_c(program.decls, some(prefix), ctx.fn_mut_params)
        // B-090: effect-op declaration order (slot contract, all modules).
        register_effect_ops_c(program.decls, ctx.effect_ops)
    }

    c_register_builtin_enums(ctx)

    // Prefix/import-aware transitive effect closure.  Bare function names are
    // not unique across modules, so both caller and callee use the exact same
    // qualified registry key as forward declarations and body emission.
    compute_project_effect_closure_c(modules, ctx.local_fn_effects)

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
            HDecl::Impl { target_type, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, .. } => {
                            // #177: qualified key matching scan_fn_effects_c
                            names.insert("${target_type}_${mn}")
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
// Built-in enums — Option/Result constructors.
// Option: { i64 tag, ptr payload }, typeid 8 (RING_TYPEID_OPTION).
//   ring_Option_some is emitted here; ring_Option_none is DEFINED by
//   ring_runtime.cpp (B-104 D6 memoised none singleton) — declaration only.
// Result: same layout, first generated typeid.  Unlike Option, Result uses the
//   ordinary generated enum drop glue registered for that typeid.
// ============================================================

fn c_register_builtin_enums(mut ctx: CCtx) {
    rt_use(ctx, "ring_alloc", 2)
    rt_use(ctx, "ring_Option_none", 0)

    // Enum registry entries — match / if-let compile against these tags and
    // layouts (register_builtin_enums parity: some=0/none=1, Ok=0/Err=1).
    let mut option_variants: Map<Str, CEnumVariantInfo> = map_new()
    option_variants.insert("some", CEnumVariantInfo { tag: 0, field_count: 1, field_names: ["value"], field_rc_skip: [false] })
    option_variants.insert("none", CEnumVariantInfo { tag: 1, field_count: 0, field_names: [], field_rc_skip: [] })
    ctx.enum_types.insert("Option", CEnumInfo { variants: option_variants, max_fields: 1 })

    let mut result_variants: Map<Str, CEnumVariantInfo> = map_new()
    result_variants.insert("Ok", CEnumVariantInfo { tag: 0, field_count: 1, field_names: ["value"], field_rc_skip: [false] })
    result_variants.insert("Err", CEnumVariantInfo { tag: 1, field_count: 1, field_names: ["value"], field_rc_skip: [false] })
    ctx.enum_types.insert("Result", CEnumInfo { variants: result_variants, max_fields: 1 })

    // Pin Option's typeid to the runtime's fixed RING_TYPEID_OPTION (8) so
    // ANY future typeid request for "Option" (e.g. a named-construct path)
    // agrees with ring_Option_some/the runtime Option makers.
    ctx.type_to_typeid.insert("Option", 8)

    ctx.functions.insert("ring_Option_some", CFnInfo { c_name: "ring_Option_some", total_params: 1 })
    ctx.functions.insert("ring_Option_none", CFnInfo { c_name: "ring_Option_none", total_params: 0 })
    ctx.functions.insert("ring_Result_Ok", CFnInfo { c_name: "ring_Result_Ok", total_params: 1 })
    ctx.functions.insert("ring_Result_Err", CFnInfo { c_name: "ring_Result_Err", total_params: 1 })
    for key in ["ring_Option_some", "ring_Result_Ok", "ring_Result_Err"] {
        ctx.ring_callable_names.insert(key)
    }
    let mut ev1: List<Str> = []
    ctx.fn_evidence_params.insert("ring_Option_some", ev1)
    let mut ev2: List<Str> = []
    ctx.fn_evidence_params.insert("ring_Option_none", ev2)
    let mut ev3: List<Str> = []
    ctx.fn_evidence_params.insert("ring_Result_Ok", ev3)
    let mut ev4: List<Str> = []
    ctx.fn_evidence_params.insert("ring_Result_Err", ev4)

    let result_tid = get_or_assign_c_typeid(ctx, "Result")

    ctx.fn_protos.push("void* ring_Option_some(void* value);")
    ctx.fn_protos.push("void* ring_Result_Ok(void* value);")
    ctx.fn_protos.push("void* ring_Result_Err(void* value);")

    let mut some_def: List<Str> = []
    some_def.push("void* ring_Option_some(void* value) {")
    some_def.push("    void* p = ring_alloc((int64_t)(sizeof(int64_t) + sizeof(void*)), 8);")
    some_def.push("    *(int64_t*)p = 0;")
    some_def.push("    *(void**)((char*)p + sizeof(int64_t)) = value;")
    some_def.push("    return p;")
    some_def.push("}")
    ctx.fn_defs.push(some_def.join("\n"))

    let mut ok_def: List<Str> = []
    ok_def.push("void* ring_Result_Ok(void* value) {")
    ok_def.push("    void* p = ring_alloc((int64_t)(sizeof(int64_t) + sizeof(void*)), ${result_tid});")
    ok_def.push("    *(int64_t*)p = 0;")
    ok_def.push("    *(void**)((char*)p + sizeof(int64_t)) = value;")
    ok_def.push("    return p;")
    ok_def.push("}")
    ctx.fn_defs.push(ok_def.join("\n"))

    let mut err_def: List<Str> = []
    err_def.push("void* ring_Result_Err(void* value) {")
    err_def.push("    void* p = ring_alloc((int64_t)(sizeof(int64_t) + sizeof(void*)), ${result_tid});")
    err_def.push("    *(int64_t*)p = 1;")
    err_def.push("    *(void**)((char*)p + sizeof(int64_t)) = value;")
    err_def.push("    return p;")
    err_def.push("}")
    ctx.fn_defs.push(err_def.join("\n"))
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
            HDecl::Fn { name, params, effects, trait_bounds, .. } => {
                let mangled = match prefix {
                    some(p) => c_mangle_fn_with_prefix(p, name),
                    none => c_mangle_fn(name),
                }
                ctx.ring_callable_names.insert(mangled)
                let effect_key = match prefix {
                    some(_) => mangled,
                    none => name,
                }
                c_declare_fn(ctx, mangled, effect_key, params, effects, trait_bounds)
            },
            HDecl::Impl { target_type, trait_name, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, params: mp, effects: me, trait_bounds: mtb, .. } => {
                            // #177: qualified effect key matching scan_fn_effects_c.
                            let method_key = c_mangle_method(target_type, mn)
                            ctx.ring_callable_names.insert(method_key)
                            c_declare_fn(ctx, method_key, "${target_type}_${mn}", mp, me, mtb)
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
                        let dict_name = trait_dict_name(target_type, tn)
                        let has_methods = methods.len() > 0
                        if has_methods && ctx.dict_build_fns.contains(dict_name) == false {
                            ctx.dict_build_fns.insert(dict_name)
                            ctx.fn_protos.push("void* ring_dict_build_${c_symbol_fragment(dict_name)}(void);")
                        }
                    },
                    none => {},
                }
            },
            HDecl::Trait { .. } => {},
            HDecl::Struct { name, fields, .. } => {
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
            HDecl::Enum { name, variants, .. } => {
                register_c_enum_info(ctx, name, variants)
                c_emit_enum_ctors(ctx, name, variants)
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
                    ctx.functions.insert(mangled, CFnInfo { c_name: c_name, total_params: 0 })
                    let mut no_ev: List<Str> = []
                    ctx.fn_evidence_params.insert(mangled, no_ev)
                    ctx.fn_protos.push("void* ${c_name}(void);")
                }
            },
            HDecl::Test { .. } => {
                // #215: test block as a zero-arg function.
                let test_name = "ring_test_${ctx.test_fns.len()}"
                ctx.functions.insert(test_name, CFnInfo { c_name: test_name, total_params: 0 })
                let mut no_ev: List<Str> = []
                ctx.fn_evidence_params.insert(test_name, no_ev)
                ctx.fn_protos.push("void* ${test_name}(void);")
                ctx.test_fns.push(test_name)
            },
            HDecl::ModBlock { decls: md, .. } => {
                // Inline-mod decl names are already module-prefixed by the
                // checker; `::` sanitizes to `__` in c_mangle_fn.
                c_forward_declare_with_prefix(ctx, md, prefix)
            },
            HDecl::Effect { .. } => {},       // ops registry: register_effect_ops_c
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
// Enum registration + variant constructors (ports of register_enum_info /
// forward_declare_enum_ctors / emit_enum_constructors).  Tags are assigned in
// declaration order; the value layout is { int64_t tag, void* f0, ... } —
// see codegen_c_ctx::CEnumInfo.  Constructors are declared AND defined in the
// forward pass: their bodies only need the registry + typeid, and this keeps
// the declare-time collision skip and the definition in one place.
// ============================================================

fn register_c_enum_info(mut ctx: CCtx, name: Str, variants: List<HEnumVariant>) {
    let mut max_fields = 0
    let mut variant_map: Map<Str, CEnumVariantInfo> = map_new()
    let mut tag = 0
    for v in variants {
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
        variant_map.insert(v.name, CEnumVariantInfo { tag: tag, field_count: fc, field_names: fnames, field_rc_skip: frs })
        tag = tag + 1
    }
    ctx.enum_types.insert(name, CEnumInfo { variants: variant_map, max_fields: max_fields })
}

fn c_emit_enum_ctors(mut ctx: CCtx, name: Str, variants: List<HEnumVariant>) {
    let max_fields = match ctx.enum_types.get(name) {
        some(ei) => ei.max_fields,
        none => panic("C codegen: enum '${name}' not registered"),
    }
    rt_use(ctx, "ring_alloc", 2)
    let tid = get_or_assign_c_typeid(ctx, name)
    let mut tag = 0
    for v in variants {
        let key = c_mangle_fn(variant_ctor_name(name, v.name))
        let vtag = tag
        tag = tag + 1
        // First-come-wins within the forward pass (forward_declare_enum_ctors
        // skip parity) — also prevents a duplicate C definition.
        if ctx.functions.contains_key(key) {
            continue
        }
        let c_name = if is_runtime_symbol(key) { "${key}__ring" } else { c_symbol_for_fn_key(key) }
        ctx.functions.insert(key, CFnInfo { c_name: c_name, total_params: v.fields.len() })
        // Only positional payload variants are first-class function values.
        // Named-field variants lower structurally; fieldless variants are
        // singleton values rather than fn() constructors.
        if v.field_names.is_none() && v.fields.len() > 0 {
            ctx.ring_callable_names.insert(key)
        }
        let mut no_ev: List<Str> = []
        ctx.fn_evidence_params.insert(key, no_ev)

        let mut ps: List<Str> = []
        for i in 0..v.fields.len() { ps.push("void* a${i}") }
        let params_str = if ps.len() == 0 { "void" } else { ps.join(", ") }
        ctx.fn_protos.push("void* ${c_name}(${params_str});")

        let mut def: List<Str> = []
        def.push("void* ${c_name}(${params_str}) {")
        def.push("    void* p = ring_alloc((int64_t)(sizeof(int64_t) + ${max_fields} * sizeof(void*)), ${tid});")
        def.push("    *(int64_t*)p = ${vtag};")
        for i in 0..v.fields.len() {
            def.push("    ((void**)p)[${i + 1}] = a${i};")
        }
        def.push("    return p;")
        def.push("}")
        ctx.fn_defs.push(def.join("\n"))
    }
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
        // A fn (or enum ctor) already owns this symbol — skip (LLVM parity).
        return
    }
    let c_name = if is_runtime_symbol(key) { "${key}__ring" } else { c_symbol_for_fn_key(key) }
    ctx.functions.insert(key, CFnInfo { c_name: c_name, total_params: fields.len() })
    let mut no_ev: List<Str> = []
    ctx.fn_evidence_params.insert(key, no_ev)

    rt_use(ctx, "ring_alloc", 2)
    let tid = get_or_assign_c_typeid(ctx, name)
    let mut ps: List<Str> = []
    for i in 0..fields.len() { ps.push("void* a${i}") }
    let params_str = if ps.len() == 0 { "void" } else { ps.join(", ") }
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

fn c_declare_fn(mut ctx: CCtx, mangled: Str, effect_key: Str, params: List<HParam>, effects: EffectRow, trait_bounds: List<TraitBound>) {
    // Effective effects: transitive closure result wins over the decl row.
    let effective = match ctx.local_fn_effects.get(effect_key) {
        some(e) => e,
        none => effects,
    }
    let ev_names = extract_effect_names(effective)
    let mut ev_params: List<Str> = []
    for en in ev_names { ev_params.push(evidence_param_name(en)) }
    ctx.fn_evidence_params.insert(mangled, ev_params)

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

    let total = params.len() + trait_bounds.len() + ev_params.len()
    ctx.functions.insert(mangled, CFnInfo { c_name: c_name, total_params: total })

    // Function-value ABI invariant: wrappers must receive one checker-resolved
    // DictRef per declared bound.
    ctx.fn_trait_bounds.insert(mangled, trait_bounds)

    let mut ps: List<Str> = []
    for _p in params { ps.push("void*") }
    for _b in trait_bounds { ps.push("void*") }
    for _e in ev_params { ps.push("void*") }
    let params_str = if ps.len() == 0 { "void" } else { ps.join(", ") }
    ctx.fn_protos.push("void* ${c_name}(${params_str});")
}

// ============================================================
// Declaration body emission
// ============================================================

fn emit_c_decl(mut ctx: CCtx, decl: HDecl) {
    match decl {
        HDecl::Fn { name, params, effects, body, trait_bounds, span, .. } => {
            emit_c_fn_body(ctx, name, params, effects, body, trait_bounds, none, span)
        },
        HDecl::Impl { target_type, trait_name, methods, .. } => {
            for m in methods {
                match m {
                    HDecl::Fn { name: mn, params: mp, effects: me, body: mb, trait_bounds: mtb, span: msp, .. } => {
                        emit_c_fn_body(ctx, mn, mp, me, mb, mtb, some(target_type), msp)
                    },
                    _ => {},
                }
            }
            // Core has already elaborated every trait/default/derived method
            // into an ordinary exact HDecl::Fn.  C only assembles the ABI dict.
            match trait_name {
                some(tn) => {
                    emit_c_trait_dict(ctx, target_type, tn, methods)
                },
                none => {},
            }
        },
        HDecl::Struct { .. } => {},
        HDecl::Enum { .. } => {},
        HDecl::Effect { .. } => {},
        HDecl::Test { body, span, .. } => {
            let test_name = ctx.test_fns[ctx.test_emit_idx]
            ctx.test_emit_idx = ctx.test_emit_idx + 1
            emit_c_zero_arg_fn(ctx, test_name, body, span)
        },
        HDecl::Trait { .. } => {},
        HDecl::ExternFn { .. } => {},
        HDecl::ExternType { .. } => {},
        HDecl::TypeAlias { .. } => {},
        HDecl::Const { name, init, span, .. } => {
            emit_c_const_body(ctx, name, init, span)
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
    ctx.in_function = false
    ctx.current_fn_name = ""
}

fn emit_c_fn_body(mut ctx: CCtx, name: Str, params: List<HParam>, effects: EffectRow, body: HExpr, trait_bounds: List<TraitBound>, impl_type: Str?, span: Span) {
    let mangled = match impl_type {
        some(t) => c_mangle_method(t, name),
        none => {
            // Step 8: module-qualified key in project mode (emit_fn_body parity).
            match ctx.module_prefix {
                some(prefix) => c_mangle_fn_with_prefix(prefix, name),
                none => c_mangle_fn(name),
            }
        },
    }
    // Definition symbol = CFnInfo.c_name (collision-renamed when needed).
    let c_name = match ctx.functions.get(mangled) {
        some(fi) => fi.c_name,
        none => panic("C codegen: function '${mangled}' not forward-declared"),
    }

    // First definition wins (see CCtx.emitted_fns): a later decl with the
    // same mangled name (user enum shadowing a prelude type's impl) would be
    // a C redefinition error; call sites all resolve to the first symbol,
    // matching the LLVM backend's effective behaviour.
    if ctx.emitted_fns.contains(c_name) { return }
    ctx.emitted_fns.insert(c_name)

    let saved = begin_c_fn(ctx, mangled)

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
    let effect_key = match impl_type {
        some(t) => "${t}_${name}",
        none => mangled,
    }
    // Single-file scans retain their historical bare keys.
    let lookup_effect_key = match ctx.module_prefix {
        some(_) => effect_key,
        none => name,
    }
    let effective = match ctx.local_fn_effects.get(lookup_effect_key) {
        some(e) => e,
        none => effects,
    }
    for en in extract_effect_names(effective) {
        let ep = evidence_param_name(en)
        let cn = c_param(ctx, ep)
        sig_parts.push("void* ${cn}")
    }
    let params_str = if sig_parts.len() == 0 { "void" } else { sig_parts.join(", ") }

    c_line_directive(ctx, span)
    let val = gen_c_expr(ctx, body)
    c_emit(ctx, "return ${val};")

    end_c_fn(ctx, c_name, params_str, saved)
}

fn emit_c_zero_arg_fn(mut ctx: CCtx, mangled: Str, body: HExpr, span: Span) {
    let saved = begin_c_fn(ctx, mangled)
    c_line_directive(ctx, span)
    let val = gen_c_expr(ctx, body)
    c_emit(ctx, "return ${val};")
    end_c_fn(ctx, mangled, "void", saved)
}

// ============================================================
// Const bodies — port of emit_const_body (B-104 D6/D9):
//   Str const  → lazy memoised getter, interned via ring_const_intern
//   enum const → lazy memoised getter, interned via ring_unit_intern
//   other      → per-access re-evaluation (fresh scalar box per call)
// ============================================================

fn emit_c_const_body(mut ctx: CCtx, name: Str, init: HExpr, span: Span) {
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
        emit_c_memoised_const(ctx, c_name, init, "ring_const_intern", span)
    } else if is_enum_const {
        emit_c_memoised_const(ctx, c_name, init, "ring_unit_intern", span)
    } else {
        emit_c_zero_arg_fn(ctx, c_name, init, span)
    }
}

fn emit_c_memoised_const(mut ctx: CCtx, mangled: Str, init: HExpr, intern_fn: Str, span: Span) {
    let g = "__ring_constg_${mangled}"
    ctx.globals.push("static void* ${g} = 0;")
    rt_use(ctx, intern_fn, 1)

    let saved = begin_c_fn(ctx, mangled)
    c_line_directive(ctx, span)
    c_emit(ctx, "if (${g} == 0) {")
    ctx.indent = ctx.indent + 1
    let built = gen_c_expr(ctx, init)
    c_emit(ctx, "${g} = ${intern_fn}(${built});")
    ctx.indent = ctx.indent - 1
    c_emit(ctx, "}")
    c_emit(ctx, "return ${g};")
    end_c_fn(ctx, mangled, "void", saved)
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
                    let user_drop_name = c_mangle_method(sname, "drop")
                    match ctx.functions.get(user_drop_name) {
                        some(fi) => {
                            def.push("    ${fi.c_name}(${c_user_drop_args(ctx, user_drop_name, fi.total_params)});")
                        },
                        none => {
                            eprintln("[drop-warn] user drop method '${user_drop_name}' not found for Drop type '${sname}'")
                        },
                    }
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
                    let user_drop_name = c_mangle_method(ename, "drop")
                    match ctx.functions.get(user_drop_name) {
                        some(fi) => {
                            def.push("    ${fi.c_name}(${c_user_drop_args(ctx, user_drop_name, fi.total_params)});")
                        },
                        none => {
                            eprintln("[drop-warn] user drop method '${user_drop_name}' not found for Drop type '${ename}'")
                        },
                    }
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

// Argument list for the user drop call inside ring_drop_<T>: `p` plus a
// filler for every extra prototype param.  Ring 0.1 Drop is effect-free, so
// an evidence parameter here is invalid typed input; RING_UNIT remains only
// the legacy ABI filler until the RcIR bridge becomes the sole emitter.
fn c_user_drop_args(ctx: CCtx, user_drop_name: Str, total_params: Int) -> Str {
    let _ = ctx
    let _ = user_drop_name
    let mut args: List<Str> = ["p"]
    for _i in 1..total_params {
        args.push("RING_UNIT")
    }
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
            let mut args: List<Str> = []
            match ctx.fn_evidence_params.get(ring_main_key) {
                some(evs) => {
                    for _ep in evs { args.push("RING_UNIT") }
                },
                none => {},
            }
            lines.push("    ${fi.c_name}(${args.join(", ")});")
        },
        none => {
            // #215: no fn main — run test functions in declaration order.
            for t in ctx.test_fns {
                lines.push("    ${t}();")
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

// ============================================================
// Step 6: effect registries.
// ============================================================

// Port of register_effect_ops_llvm — effect name -> declared ops (slot order).
fn register_effect_ops_c(decls: List<HDecl>, mut effect_ops: Map<Str, List<HEffectOp>>) {
    for decl in decls {
        match decl {
            HDecl::Effect { name, ops, .. } => {
                effect_ops.insert(name, ops)
            },
            HDecl::ModBlock { decls: md, .. } => {
                register_effect_ops_c(md, effect_ops)
            },
            _ => {},
        }
    }
}

// ============================================================
// Effect scanning — C-native source of truth for local/transitive effect
// discovery and local-name collection.
// ============================================================

fn scan_fn_effects_c(decls: List<HDecl>, mut local_fn_effects: Map<Str, EffectRow>) {
    scan_fn_effects_with_prefix_c(decls, none, local_fn_effects)
}

// In project mode top-level functions are keyed exactly like the function
// registry.  Impl methods retain the shared Type_method ABI used by both
// backends.
fn scan_fn_effects_with_prefix_c(decls: List<HDecl>, prefix: Str?, mut local_fn_effects: Map<Str, EffectRow>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, effects, .. } => {
                if effects.effects.len() > 0 {
                    let key = match prefix {
                        some(p) => c_mangle_fn_with_prefix(p, name),
                        none => name,
                    }
                    local_fn_effects.insert(key, effects)
                }
            },
            HDecl::Impl { target_type, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, effects: me, .. } => {
                            if me.effects.len() > 0 {
                                let key = "${target_type}_${mn}"
                                local_fn_effects.insert(key, me)
                            }
                        },
                        _ => {},
                    }
                }
            },
            HDecl::ModBlock { decls: md, .. } => {
                scan_fn_effects_with_prefix_c(md, prefix, local_fn_effects)
            },
            _ => {},
        }
    }
}

// A value type (Int/Float/Bool/Str) is the only kind a `mut` param boxes
// into a CELL (#B-087 gap 5).
fn c_is_value_type(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::BoolType => true,
        Type::StrType => true,
        _ => false,
    }
}

fn mut_param_flags_c(params: List<HParam>) -> List<Bool> {
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

fn scan_fn_mut_params_c(decls: List<HDecl>, mut fn_mut_params: Map<Str, List<Bool>>) {
    scan_fn_mut_params_with_prefix_c(decls, none, fn_mut_params)
}

fn scan_fn_mut_params_with_prefix_c(decls: List<HDecl>, prefix: Str?, mut fn_mut_params: Map<Str, List<Bool>>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, params, .. } => {
                let key = match prefix {
                    some(p) => c_mangle_fn_with_prefix(p, name),
                    none => name,
                }
                fn_mut_params.insert(key, mut_param_flags_c(params))
            },
            HDecl::Impl { target_type, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, params: mp, .. } => {
                            let ufcs_name = "${target_type}_${mn}"
                            fn_mut_params.insert(ufcs_name, mut_param_flags_c(mp))
                        },
                        _ => {},
                    }
                }
            },
            HDecl::ModBlock { decls: md, .. } => {
                scan_fn_mut_params_with_prefix_c(md, prefix, fn_mut_params)
            },
            _ => {},
        }
    }
}

fn collect_local_names_rec_c(decls: List<HDecl>, mut names: Set<Str>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, .. } => { names.insert(name) },
            HDecl::Impl { target_type, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, .. } => { names.insert("${target_type}_${mn}") },
                        _ => {},
                    }
                }
            },
            HDecl::ModBlock { decls: md, .. } => { collect_local_names_rec_c(md, names) },
            _ => {},
        }
    }
}

fn compute_transitive_effect_closure_c(decls: List<HDecl>, mut local_fn_effects: Map<Str, EffectRow>) {
    if local_fn_effects.len() == 0 { return }
    let mut local_names: Set<Str> = set_new()
    collect_local_names_rec_c(decls, local_names)
    let mut fn_callees: Map<Str, Set<Str>> = map_new()
    collect_fn_callees(decls, local_names, fn_callees)
    propagate_transitive_effects_c(fn_callees, local_fn_effects)
}

// Record whether a callee-analysis key denotes a top-level/module function or
// a globally-keyed impl method.  `collect_fn_callees` intentionally emits bare
// HIR names; this metadata lets project mode translate them to registry keys.
fn collect_project_callable_kinds_c(decls: List<HDecl>, mut top_level: Set<Str>, mut impl_methods: Set<Str>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, .. } => { top_level.insert(name) },
            HDecl::Impl { target_type, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name, .. } => { impl_methods.insert("${target_type}_${name}") },
                        _ => {},
                    }
                }
            },
            HDecl::ModBlock { decls: md, .. } => collect_project_callable_kinds_c(md, top_level, impl_methods),
            _ => {},
        }
    }
}

fn project_effect_key_c(prefix: Str, name: Str, top_level: Set<Str>, impl_methods: Set<Str>, imports: Map<Str, Str>) -> Str {
    match imports.get(name) {
        some(key) => key,
        none => {
            if impl_methods.contains(name) {
                name
            } else if top_level.contains(name) {
                c_mangle_fn_with_prefix(prefix, name)
            } else {
                name
            }
        },
    }
}

fn compute_project_effect_closure_c(modules: List<(Str, HProgram, List<UseDecl>)>, mut local_fn_effects: Map<Str, EffectRow>) {
    let mut qualified_callees: Map<Str, Set<Str>> = map_new()
    for m in modules {
        let (prefix, program, uses) = m
        let imports = build_c_imports_map(uses)
        let mut top_level: Set<Str> = set_new()
        let mut impl_methods: Set<Str> = set_new()
        collect_project_callable_kinds_c(program.decls, top_level, impl_methods)

        // The shared traversal only records names present in local_names.
        // Imported aliases are callable too, so include them for this module.
        let mut analysis_names: Set<Str> = set_new()
        collect_local_names_rec_c(program.decls, analysis_names)
        let mut sorted_imports = imports.entries()
        sorted_imports.sort_by(compare_by_first)
        for entry in sorted_imports { analysis_names.insert(entry.0) }

        let mut bare_callees: Map<Str, Set<Str>> = map_new()
        collect_fn_callees(program.decls, analysis_names, bare_callees)
        let mut sorted_callers = bare_callees.entries()
        sorted_callers.sort_by(compare_by_first)
        for entry in sorted_callers {
            let (caller, callees) = entry
            let caller_key = project_effect_key_c(prefix, caller, top_level, impl_methods, imports)
            let mut mapped: Set<Str> = set_new()
            let mut sorted_callees = callees.to_list()
            sorted_callees.sort()
            for callee in sorted_callees {
                mapped.insert(project_effect_key_c(prefix, callee, top_level, impl_methods, imports))
            }
            qualified_callees.insert(caller_key, mapped)
        }
    }
    propagate_transitive_effects_c(qualified_callees, local_fn_effects)
}

fn propagate_transitive_effects_c(fn_callees: Map<Str, Set<Str>>, mut local_fn_effects: Map<Str, EffectRow>) {
    let mut changed = true
    while changed {
        changed = false
        let mut sorted_callees = fn_callees.entries()
        sorted_callees.sort_by(compare_by_first)
        for entry in sorted_callees {
            let (name, callees) = entry
            let mut sorted_callee_names = callees.to_list()
            sorted_callee_names.sort()
            for callee in sorted_callee_names {
                match local_fn_effects.get(callee) {
                    some(callee_effects) => {
                        match local_fn_effects.get(name) {
                            none => {
                                let mut effs: List<Effect> = []
                                for e in callee_effects.effects { effs.push(e) }
                                local_fn_effects.insert(name, EffectRow { effects: effs, tail: none })
                                changed = true
                            },
                            some(current) => {
                                for e in callee_effects.effects {
                                    let ename = effect_kind_name(e)
                                    let mut found = false
                                    for ce in current.effects {
                                        if effect_kind_name(ce) == ename { found = true }
                                    }
                                    if found == false {
                                        current.effects.push(e)
                                        changed = true
                                    }
                                }
                            },
                        }
                    },
                    none => {},
                }
            }
        }
    }
}

// ============================================================
// Mechanical trait dict emission for exact ordinary impl methods.
// Dict layout { i64 method_count, ptr m0, ... } typeid 16 (DICT_STATIC);
// each slot is a {thunk, env} closure (typeid 7).
// ============================================================

fn emit_c_trait_dict(mut ctx: CCtx, target_type: Str, trait_name: Str, methods: List<HDecl>) {
    let dict_name = trait_dict_name(target_type, trait_name)

    let mut method_order: List<Str> = []
    for m in methods {
        match m {
            HDecl::Fn { name, impl_method_ref, .. } => {
                let exact = match impl_method_ref {
                    some(value) => value,
                    none => panic(
                        "C ABI dict: ordinary impl method lacks exact identity")
                }
                if impl_method_ref_callable_slot_index(exact) !=
                        method_order.len() {
                    panic("C ABI dict: exact method slot order differs")
                }
                method_order.push(name)
            },
            _ => panic("C ABI dict: impl method carrier is not a function"),
        }
    }
    let method_count = method_order.len()
    if method_count == 0 { return }

    let build_fn_name = "ring_dict_build_${c_symbol_fragment(dict_name)}"
    if ctx.emitted_fns.contains(build_fn_name) { return }
    ctx.emitted_fns.insert(build_fn_name)
    // Defensive ABI registration if the forward pass did not predeclare it.
    if ctx.dict_build_fns.contains(dict_name) == false {
        ctx.dict_build_fns.insert(dict_name)
        ctx.fn_protos.push("void* ${build_fn_name}(void);")
    }

    let saved = c_push_fn(ctx, build_fn_name)
    rt_use(ctx, "ring_alloc", 2)
    let dict = fresh_tmp(ctx)
    c_emit(ctx, "${dict} = ring_alloc((int64_t)(sizeof(int64_t) + ${method_count} * sizeof(void*)), 16);")
    c_emit(ctx, "*(int64_t*)${dict} = ${method_count};")
    for i in 0..method_count {
        match method_order.get(i) {
            some(method_name) => {
                emit_c_dict_method_slot(
                    ctx, target_type, method_name, dict, i)
            },
            none => {},
        }
    }
    c_emit(ctx, "return ${dict};")
    c_pop_fn(ctx, build_fn_name, "void", saved)

    // Memoised getter (routes through the build fn — dict_build_fns entry).
    let _g = ensure_c_dict_getter(ctx, dict_name)
}

fn emit_c_dict_method_slot(
    mut ctx: CCtx, target_type: Str, method_name: Str,
    dict_var: Str, slot_idx: Int
) {
    let mangled = c_mangle_method(target_type, method_name)
    match ctx.functions.get(mangled) {
        some(fi) => {
            // Direct-ABI impl method behind an env-dropping thunk (B-092).
            let thunk = ensure_c_dict_method_thunk(ctx, fi.c_name, fi.total_params)
            let cls = fresh_tmp(ctx)
            c_emit(ctx, "${cls} = ring_alloc((int64_t)(2 * sizeof(void*)), 7);")
            c_emit(ctx, "((void**)${cls})[0] = (void*)${thunk};")
            c_emit(ctx, "((void**)${cls})[1] = RING_UNIT;")
            c_emit(ctx, "((void**)${dict_var})[${slot_idx + 1}] = ${cls};")
        },
        none => panic("C ABI dict: exact ordinary method was not declared"),
    }
}

// Env-dropping thunk for a direct-ABI impl method: fn(env, p0..pN-1) →
// method(p0..pN-1).  N = the method's FULL arity (incl. dicts/evidence) —
// callers through the closure ABI supply the leading user args (LLVM parity).
fn ensure_c_dict_method_thunk(mut ctx: CCtx, method_c_name: Str, method_arity: Int) -> Str {
    let thunk_name = "${method_c_name}__dictthunk"
    if ctx.emitted_fns.contains(thunk_name) { return thunk_name }
    ctx.emitted_fns.insert(thunk_name)
    let mut sig_parts: List<Str> = ["void* env"]
    let mut fwd: List<Str> = []
    for i in 0..method_arity {
        sig_parts.push("void* p${i}")
        fwd.push("p${i}")
    }
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
