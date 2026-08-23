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
    HTraitMethod, HEffectOp, TraitBound, evidence_param_name, trait_bound_param_name,
    effect_name_from_evidence_param, default_evidence_name,
    variant_ctor_name, compare_by_first, hexpr_type, trait_dict_name,
    default_method_self_name, scan_trait_method_order, collect_all_supertraits,
    type_contains_extern_handle,
    DerivedImpl, DerivedField, DerivedVariant, FieldAction, DictRef, TypeKind,
    DERIVED_HASH_SEED}
use codegen_c_ctx::{CCtx, CFnInfo, CStructInfo, CEnumInfo, CEnumVariantInfo, CTypedRef,
    CEmitState, new_c_ctx, c_emit, c_raw, c_param, c_param_def,
    c_local, c_mangle_fn,
    c_mangle_fn_with_prefix, c_mangle_method, c_sanitize, c_symbol_for_fn_key, c_symbol_fragment,
    c_line_directive,
    rt_use, rt_use_raw,
    get_or_assign_c_typeid, is_runtime_symbol, fresh_tmp, fresh_i64, fresh_dbl,
    fresh_label, c_push_fn, c_pop_fn, c_global_cstr, c_ref_c_name,
    c_enable_identity_ledger, c_identity_ledger_text}
use codegen_c_expr::{gen_c_expr, emit_c_stmt, c_resolve_dict_ref,
    ensure_c_dict_getter, gen_c_closure_call, emit_c_receiver_load,
    emit_c_default_evidence_init}
use effect_analysis::{extract_effect_names, collect_fn_callees}
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

    // Step 6: effect op declarations (slot-order contract) + B-097 default
    // evidence globals.  The globals must be registered BEFORE the body pass
    // so c_lookup_evidence's off-scope fallback resolves to them; the init
    // function that populates them is emitted after the body pass.
    register_effect_ops_c(program.decls, ctx.effect_ops)
    register_c_default_evidence(ctx)

    // First pass: prototypes + registries (enum variant ctors are declared
    // AND defined here — their bodies depend on nothing but the registries).
    // Also pre-registers every impl trait dict's build fn (dict_build_fns) so
    // getter routing is decl-order-independent, and forward-declares default
    // trait method fns (__<Trait>_<method>).
    c_forward_declare(ctx, program.decls)

    // Struct constructors after the whole forward pass: a Ring fn sharing the
    // struct's name wins the ring_<Name> symbol regardless of declaration
    // order (the LLVM backend gets this by emitting struct ctors in pass 2,
    // after every fn was declared).
    c_declare_struct_ctors(ctx, program.decls)

    // Derived trait impls (Eq/Clone/Ord/Debug/Json) BEFORE the body pass — method
    // calls in bodies need ring_<Type>_clone etc. registered. Builtin Option
    // descriptors are already part of the checker-owned HProgram inventory.
    emit_c_derived_impls(ctx, program.derived_impls)

    // Second pass: function bodies (+ impl trait dict build fns, default
    // trait method bodies, default-method forwarding stubs).
    for decl in program.decls {
        emit_c_decl(ctx, decl)
    }

    // Step 7: per-type drop functions (port of emit_drop_functions) + the
    // ring_register_drop statements consumed by the main wrapper below.
    emit_c_drop_functions(ctx)

    // B-097: default evidence init fn (port of build_default_evidence_all —
    // the LLVM backend builds these inline in main's entry block; C uses a
    // synthesised init fn called from main before ring_main).
    emit_c_default_evidence_init(ctx)

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

    register_c_default_evidence(ctx)

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

    // Derived trait impls before the body pass. The project assembler prepends
    // builtin Option descriptors to its one physical carrier HProgram.
    // Register every Json method/builder/getter across the project before any
    // Json body is emitted, so declaration order cannot select a fallback.
    for m in modules {
        let (_prefix, program, _uses) = m
        predeclare_c_json_derived_impls(ctx, program.derived_impls)
    }
    for m in modules {
        let (_prefix, program, _uses) = m
        emit_c_derived_impl_bodies(ctx, program.derived_impls)
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

    // Drop functions + default evidence init + C main (entry module's main).
    emit_c_drop_functions(ctx)
    emit_c_default_evidence_init(ctx)
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
                        let has_methods = match ctx.trait_method_order.get(tn) {
                            some(order) => order.len() > 0,
                            none => methods.len() > 0,
                        }
                        if has_methods && ctx.dict_build_fns.contains(dict_name) == false {
                            ctx.dict_build_fns.insert(dict_name)
                            ctx.fn_protos.push("void* ring_dict_build_${c_symbol_fragment(dict_name)}(void);")
                        }
                    },
                    none => {},
                }
            },
            HDecl::Trait { name: trait_name, methods: trait_methods, .. } => {
                // B-141: forward-declare default trait method bodies as
                // __<Trait>_<method>(self_dict, ...supertrait_dicts, ...params,
                // ...evidence) — port of the LLVM forward pass Trait arm.
                let all_supers = collect_all_supertraits(ctx.trait_supertraits, trait_name)
                for tm in trait_methods {
                    if tm.has_default {
                        match tm.body {
                            some(_) => {
                                let default_fn_name = "__${trait_name}_${tm.name}"
                                if ctx.functions.contains_key(default_fn_name) == false {
                                    let mut ev_params: List<Str> = []
                                    for en in extract_effect_names(tm.effects) {
                                        ev_params.push(evidence_param_name(en))
                                    }
                                    let total = 1 + all_supers.len() + tm.params.len() + ev_params.len()
                                    let c_name = c_symbol_fragment(default_fn_name)
                                    ctx.functions.insert(default_fn_name, CFnInfo { c_name: c_name, total_params: total })
                                    ctx.fn_evidence_params.insert(default_fn_name, ev_params)
                                    let mut ps: List<Str> = []
                                    for _i in 0..total { ps.push("void*") }
                                    ctx.fn_protos.push("void* ${c_name}(${ps.join(", ")});")
                                }
                            },
                            none => {},
                        }
                    }
                }
            },
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
            // Trait impl: build the dict, then emit forwarding stubs for
            // default methods the impl doesn't override (stub AFTER dict so
            // the dict getter routes to the real dict — LLVM parity).
            match trait_name {
                some(tn) => {
                    emit_c_trait_dict(ctx, target_type, tn, methods)
                    emit_c_default_method_stubs(ctx, target_type, tn, methods)
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
        HDecl::Trait { name: trait_name, methods: trait_methods, .. } => {
            // B-141: emit default trait method bodies.
            emit_c_trait_default_methods(ctx, trait_name, trait_methods)
        },
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
// ABI note: the user drop call passes RING_UNIT / the default-evidence global
// for the drop method's evidence params, so the generated call matches the
// complete C prototype rather than relying on unspecified register contents.
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
// filler for every extra prototype param — trait-bound dicts (none for Drop
// impls in practice) get RING_UNIT, evidence params get the B-097 default
// evidence global when the effect has one (io/fail/handler-only effects get
// RING_UNIT, same convention as the ring_main call below).
fn c_user_drop_args(ctx: CCtx, user_drop_name: Str, total_params: Int) -> Str {
    let no_ev: List<Str> = []
    let ev = match ctx.fn_evidence_params.get(user_drop_name) {
        some(e) => e,
        none => no_ev,
    }
    let mut args: List<Str> = ["p"]
    for _i in 1..(total_params - ev.len()) {
        args.push("RING_UNIT")
    }
    for ep in ev {
        let effect_name = effect_name_from_evidence_param(ep)
        match ctx.default_evidence.get(effect_name) {
            some(g) => args.push(g),
            none => args.push("RING_UNIT"),
        }
    }
    args.join(", ")
}

// ============================================================
// C main() wrapper — parity with emit_c_main_common:
//   ring_runtime_init(argc, argv) → drop registrations (step 7) →
//   __ring_default_evidence_init (B-097, when any effect has all-default
//   ops) → ring_main(default evidence…) or test functions → return 0.
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
    // any Ring code runs (LLVM parity: emit_drop_registrations precedes the
    // default-evidence construction in main's entry block).
    for reg in ctx.drop_registrations {
        lines.push("    ${reg}")
    }
    if ctx.default_evidence.len() > 0 {
        lines.push("    __ring_default_evidence_init();")
    }
    match ctx.functions.get(ring_main_key) {
        some(fi) => {
            let mut args: List<Str> = []
            match ctx.fn_evidence_params.get(ring_main_key) {
                some(evs) => {
                    // B-097: pass the default evidence global for effects that
                    // have one; NULL for io/fail/unknown effects (the runtime
                    // handles those without evidence).
                    for ep in evs {
                        let effect_name = effect_name_from_evidence_param(ep)
                        match ctx.default_evidence.get(effect_name) {
                            some(g) => args.push(g),
                            none => args.push("RING_UNIT"),
                        }
                    }
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

// B-097: register one `static void*` global per effect whose ops ALL have
// default bodies (build_default_evidence_all's selection rule).  The global
// name comes from the shared hir::default_evidence_name convention,
// sanitized to the C identifier set.  Sorted for deterministic output.
fn register_c_default_evidence(mut ctx: CCtx) {
    let mut effect_names: List<Str> = []
    for entry in ctx.effect_ops.entries() {
        let (ename, ops) = entry
        let mut all_have_defaults = true
        for op in ops {
            if !op.has_default { all_have_defaults = false }
        }
        if all_have_defaults && ops.len() > 0 {
            effect_names.push(ename)
        }
    }
    effect_names.sort()
    for ename in effect_names {
        let g = c_symbol_fragment(default_evidence_name(ename))
        ctx.globals.push("static void* ${g} = 0;")
        ctx.default_evidence.insert(ename, g)
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
// B-141: default trait method bodies (port of emit_trait_default_methods /
// emit_one_default_method).  __<Trait>_<method>(self_dict,
// ...supertrait_dicts, ...params, ...evidence): self_dict is registered as
// __ring_self_<Trait> so body DictDispatchInfo references find it.
// ============================================================

fn emit_c_trait_default_methods(mut ctx: CCtx, trait_name: Str, methods: List<HTraitMethod>) {
    for method in methods {
        if !method.has_default { continue }
        match method.body {
            some(body) => {
                let default_fn_name = "__${trait_name}_${method.name}"
                match ctx.functions.get(default_fn_name) {
                    some(fi) => {
                        emit_c_one_default_method(ctx, fi.c_name, default_fn_name, trait_name, method, body)
                    },
                    none => {},  // not forward-declared, skip
                }
            },
            none => {},
        }
    }
}

fn emit_c_one_default_method(mut ctx: CCtx, c_name: Str, default_fn_name: Str, trait_name: Str, method: HTraitMethod, body: HExpr) {
    if ctx.emitted_fns.contains(c_name) { return }
    ctx.emitted_fns.insert(c_name)

    let saved = c_push_fn(ctx, default_fn_name)
    let mut sig_parts: List<Str> = []

    // Param 0: self_dict, registered under __ring_self_<Trait>.
    let self_dict_name = default_method_self_name(trait_name)
    let sd = c_param(ctx, self_dict_name)
    sig_parts.push("void* ${sd}")

    // Supertrait dict params, each under __ring_self_<SuperTrait>.
    let all_supers = collect_all_supertraits(ctx.trait_supertraits, trait_name)
    for st in all_supers {
        let sv = c_param(ctx, default_method_self_name(st))
        sig_parts.push("void* ${sv}")
    }

    // Regular params (including self).
    for p in method.params {
        let pv = c_param_def(ctx, p.name, p.def_id)
        sig_parts.push("void* ${pv}")
    }

    // Evidence params from the method effects.
    for en in extract_effect_names(method.effects) {
        let ev = c_param(ctx, evidence_param_name(en))
        sig_parts.push("void* ${ev}")
    }

    let val = gen_c_expr(ctx, body)
    c_emit(ctx, "return ${val};")
    c_pop_fn(ctx, c_name, sig_parts.join(", "), saved)
}

// ============================================================
// Trait dict emission for impl blocks (port of emit_trait_dict /
// emit_dict_method_slot / emit_dict_method_thunk / emit_default_method_thunk).
// Dict layout { i64 method_count, ptr m0, ... } typeid 16 (DICT_STATIC);
// each slot is a {thunk, env} closure (typeid 7).
// ============================================================

fn emit_c_trait_dict(mut ctx: CCtx, target_type: Str, trait_name: Str, methods: List<HDecl>) {
    let dict_name = trait_dict_name(target_type, trait_name)

    let mut impl_methods: List<Str> = []
    for m in methods {
        match m {
            HDecl::Fn { name, .. } => impl_methods.push(name),
            _ => {},
        }
    }
    let method_order = match ctx.trait_method_order.get(trait_name) {
        some(order) => order,
        none => impl_methods,
    }
    let method_count = method_order.len()
    if method_count == 0 { return }

    let build_fn_name = "ring_dict_build_${c_symbol_fragment(dict_name)}"
    if ctx.emitted_fns.contains(build_fn_name) { return }
    ctx.emitted_fns.insert(build_fn_name)
    // Defensive: a dict whose forward pass was skipped (trait_method_order
    // miss) still needs registration + prototype.
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
                emit_c_dict_method_slot(ctx, target_type, trait_name, method_name, dict, i)
            },
            none => {},
        }
    }
    c_emit(ctx, "return ${dict};")
    c_pop_fn(ctx, build_fn_name, "void", saved)

    // Memoised getter (routes through the build fn — dict_build_fns entry).
    let _g = ensure_c_dict_getter(ctx, dict_name)
}

fn emit_c_dict_method_slot(mut ctx: CCtx, target_type: Str, trait_name: Str, method_name: Str, dict_var: Str, slot_idx: Int) {
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
        none => {
            // B-141: default trait method — env = the dict itself, so the
            // default body dispatches self.method() through it.
            let default_fn_name = "__${trait_name}_${method_name}"
            match ctx.functions.get(default_fn_name) {
                some(dfi) => {
                    let thunk = ensure_c_default_method_thunk(ctx, default_fn_name, dfi, target_type, trait_name)
                    let cls = fresh_tmp(ctx)
                    c_emit(ctx, "${cls} = ring_alloc((int64_t)(2 * sizeof(void*)), 7);")
                    c_emit(ctx, "((void**)${cls})[0] = (void*)${thunk};")
                    c_emit(ctx, "((void**)${cls})[1] = ${dict_var};")
                    c_emit(ctx, "((void**)${dict_var})[${slot_idx + 1}] = ${cls};")
                },
                none => {
                    c_emit(ctx, "((void**)${dict_var})[${slot_idx + 1}] = RING_UNIT;")
                },
            }
        },
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

// B-141: default-method thunk — FORWARDS env (= dict ptr) as self_dict,
// resolves supertrait dicts statically for the concrete target type.
fn ensure_c_default_method_thunk(mut ctx: CCtx, default_fn_name: Str, dfi: CFnInfo, target_type: Str, trait_name: Str) -> Str {
    let thunk_name = "${dfi.c_name}__defaultthunk_${c_symbol_fragment(target_type)}"
    if ctx.emitted_fns.contains(thunk_name) { return thunk_name }
    ctx.emitted_fns.insert(thunk_name)

    let all_supers = collect_all_supertraits(ctx.trait_supertraits, trait_name)
    let thunk_arity = dfi.total_params - all_supers.len()

    // Supertrait dict getters (ensure BEFORE assembling the thunk text).
    let mut super_calls: List<Str> = []
    for st in all_supers {
        let g = ensure_c_dict_getter(ctx, trait_dict_name(target_type, st))
        super_calls.push("${g}()")
    }

    let mut sig_parts: List<Str> = []
    for i in 0..thunk_arity {
        sig_parts.push("void* p${i}")
    }
    let mut fwd: List<Str> = ["p0"]
    for sc in super_calls { fwd.push(sc) }
    for i in 1..thunk_arity { fwd.push("p${i}") }
    ctx.fn_protos.push("void* ${thunk_name}(${sig_parts.join(", ")});")
    let mut def: List<Str> = []
    def.push("void* ${thunk_name}(${sig_parts.join(", ")}) {")
    def.push("    return ${dfi.c_name}(${fwd.join(", ")});")
    def.push("}")
    ctx.fn_defs.push(def.join("\n"))
    thunk_name
}

// B-141: forwarding stubs ring_<Type>_<method> for default methods the impl
// does not override (direct calls like cat.greet() compile to these).
fn emit_c_default_method_stubs(mut ctx: CCtx, target_type: Str, trait_name: Str, impl_methods: List<HDecl>) {
    let mut impl_method_names: Set<Str> = set_new()
    for m in impl_methods {
        match m {
            HDecl::Fn { name, .. } => { impl_method_names.insert(name) },
            _ => {},
        }
    }
    let method_order_opt = ctx.trait_method_order.get(trait_name)
    if method_order_opt.is_none() { return }
    let method_order = method_order_opt.unwrap()
    let all_supers = collect_all_supertraits(ctx.trait_supertraits, trait_name)
    let super_count = all_supers.len()

    for method_name in method_order {
        if impl_method_names.contains(method_name) { continue }
        let default_fn_name = "__${trait_name}_${method_name}"
        match ctx.functions.get(default_fn_name) {
            some(dfi) => {
                let mangled = c_mangle_method(target_type, method_name)
                if ctx.functions.contains_key(mangled) { continue }
                let stub_arity = dfi.total_params - 1 - super_count
                let c_name = if is_runtime_symbol(mangled) { "${mangled}__ring" } else { mangled }
                ctx.functions.insert(mangled, CFnInfo { c_name: c_name, total_params: stub_arity })
                match ctx.fn_evidence_params.get(default_fn_name) {
                    some(ev) => { ctx.fn_evidence_params.insert(mangled, ev) },
                    none => {},
                }

                // Dict getters resolved statically for the concrete type.
                let dict_getter = ensure_c_dict_getter(ctx, trait_dict_name(target_type, trait_name))
                let mut fwd: List<Str> = ["${dict_getter}()"]
                for st in all_supers {
                    let g = ensure_c_dict_getter(ctx, trait_dict_name(target_type, st))
                    fwd.push("${g}()")
                }
                let mut sig_parts: List<Str> = []
                for i in 0..stub_arity {
                    sig_parts.push("void* p${i}")
                    fwd.push("p${i}")
                }
                let params_str = if sig_parts.len() == 0 { "void" } else { sig_parts.join(", ") }
                ctx.fn_protos.push("void* ${c_name}(${params_str});")
                let mut def: List<Str> = []
                def.push("void* ${c_name}(${params_str}) {")
                def.push("    return ${dfi.c_name}(${fwd.join(", ")});")
                def.push("}")
                ctx.fn_defs.push(def.join("\n"))
            },
            none => {},
        }
    }
}

// ============================================================
// B-100 Fix 2 port: C codegen for auto-derived trait impls
// (Eq/Hash/Clone/Ord/Debug) and the per-trait method emitters, rendered as
// plain C (no phi/bb bookkeeping). Identity and builtin descriptor assembly
// are checker responsibilities; this backend consumes the list mechanically.
// ============================================================

pub fn emit_c_derived_impls(mut ctx: CCtx, derived_impls: List<DerivedImpl>) {
    predeclare_c_json_derived_impls(ctx, derived_impls)
    emit_c_derived_impl_bodies(ctx, derived_impls)
}

fn emit_c_derived_impl_bodies(mut ctx: CCtx, derived_impls: List<DerivedImpl>) {
    for di in derived_impls {
        match di.trait_name {
            "Eq" => emit_c_derived_eq(ctx, di),
            "Clone" => emit_c_derived_clone(ctx, di),
            "Debug" => emit_c_derived_debug(ctx, di),
            "Ord" => emit_c_derived_ord(ctx, di),
            "Hash" => emit_c_derived_hash(ctx, di),
            "Json" => emit_c_derived_json(ctx, di),
            _ => {},
        }
    }
}

// ── scaffold ─────────────────────────────────────────────────

struct CDerivedFn {
    c_name: Str,
    params_str: Str,
    self_var: Str,
    other_var: Str,
    saved: CEmitState
}

// Collect every bound's type parameter and trait in exact registered ABI order.
fn collect_c_derived_dict_params(bounds: List<TraitBound>) -> List<Str> {
    let mut params: List<Str> = []
    for b in bounds {
        params.push(trait_bound_param_name(b.type_param, b.trait_name))
    }
    params
}

fn predeclare_c_derived_fn(
    mut ctx: CCtx, type_name: Str, method_name: Str,
    is_binary: Bool, bounds: List<TraitBound>
) {
    let mangled = c_mangle_method(type_name, method_name)
    if ctx.functions.contains_key(mangled) { return }
    let dict_params = collect_c_derived_dict_params(bounds)
    let base = if is_binary { 2 } else { 1 }
    let total = base + dict_params.len()
    let c_name = if is_runtime_symbol(mangled) { "${mangled}__ring" } else { mangled }
    ctx.functions.insert(mangled, CFnInfo {
        c_name: c_name,
        total_params: total
    })
    ctx.predeclared_derived_fns.insert(mangled)
    let mut no_ev: List<Str> = []
    ctx.fn_evidence_params.insert(mangled, no_ev)
    ctx.fn_trait_bounds.insert(mangled, bounds)
    let mut ps: List<Str> = []
    for _i in 0..total { ps.push("void*") }
    ctx.fn_protos.push("void* ${c_name}(${ps.join(", ")});")
}

// Begin a derived method fn: register + prototype + nested push + param
// binds (dict params land in named_values for resolve_c_dict_for_derived).
// Returns none when the method already exists (manual impl wins).
fn begin_c_derived_fn(mut ctx: CCtx, type_name: Str, method_name: Str, trait_name: Str, is_binary: Bool, bounds: List<TraitBound>) -> CDerivedFn? {
    let mangled = c_mangle_method(type_name, method_name)
    if !ctx.predeclared_derived_fns.contains(mangled) {
        if ctx.functions.contains_key(mangled) { return none }
        predeclare_c_derived_fn(ctx, type_name, method_name, is_binary, bounds)
    }

    let fn_info = match ctx.functions.get(mangled) {
        some(found) => found,
        none => return none
    }
    if ctx.emitted_fns.contains(fn_info.c_name) { return none }
    ctx.emitted_fns.insert(fn_info.c_name)

    let dict_params = collect_c_derived_dict_params(bounds)
    let base = if is_binary { 2 } else { 1 }
    let total = base + dict_params.len()
    if fn_info.total_params != total {
        panic("C codegen invariant: derived method ABI changed after predeclaration")
    }
    let c_name = fn_info.c_name

    let saved = c_push_fn(ctx, c_name)
    let mut sig_parts: List<Str> = []
    let self_var = c_param(ctx, "self")
    sig_parts.push("void* ${self_var}")
    let other_var = if is_binary {
        let ov = c_param(ctx, "other")
        sig_parts.push("void* ${ov}")
        ov
    } else {
        ""
    }
    for dp in dict_params {
        let dv = c_param(ctx, dp)
        sig_parts.push("void* ${dv}")
    }
    let params_str = sig_parts.join(", ")
    some(CDerivedFn { c_name: c_name, params_str: params_str, self_var: self_var, other_var: other_var, saved: saved })
}

fn end_c_derived_fn(mut ctx: CCtx, d: CDerivedFn) {
    c_pop_fn(ctx, d.c_name, d.params_str, d.saved)
}

// Resolve an explicitly tagged derived base.  Bound bases are Simple and
// module singleton bases are Static; spelling never selects the domain.
fn resolve_c_dict_for_derived(mut ctx: CCtx, base_dict: DictRef) -> CTypedRef {
    c_resolve_dict_ref(ctx, base_dict)
}

// Call a dict's slot-0 closure on the given args (+ resolved extra dicts) —
// shared shape of the derived eq/cmp/debug dict calls.
fn emit_c_derived_dict_call(mut ctx: CCtx, base_dict: DictRef, extra_dicts: List<DictRef>, args: List<Str>) -> Str {
    let resolved_dict = resolve_c_dict_for_derived(ctx, base_dict)
    let cls_ref = emit_c_receiver_load(ctx, resolved_dict, 1, "dict")
    let mut call_args: List<Str> = []
    let mut owned_extra_dicts: List<Str> = []
    for a in args { call_args.push(a) }
    for ed in extra_dicts {
        match ed {
            DictRef::Wrapped { dict, trait_name, inner_dicts } => {
                let reference = c_resolve_dict_ref(ctx, DictRef::Wrapped {
                    dict: dict, trait_name: trait_name, inner_dicts: inner_dicts
                })
                let value = c_ref_c_name(reference)
                call_args.push(value)
                owned_extra_dicts.push(value)
            },
            DictRef::Simple(name) => {
                let reference = c_resolve_dict_ref(ctx, DictRef::Simple(name))
                call_args.push(c_ref_c_name(reference))
            },
            DictRef::Static(name) => {
                let reference = c_resolve_dict_ref(ctx, DictRef::Static(name))
                call_args.push(c_ref_c_name(reference))
            },
        }
    }
    let result = gen_c_closure_call(ctx, cls_ref, call_args)
    for owned in owned_extra_dicts {
        rt_use(ctx, "ring_drop", 1)
        c_emit(ctx, "ring_drop(${owned});")
    }
    result
}

// A fresh Str literal value (fresh alloc, RC=1) — derived debug pieces.
fn c_derived_str_lit(mut ctx: CCtx, s: Str) -> Str {
    rt_use(ctx, "ring_str_from_cstr", 1)
    let g = c_global_cstr(ctx, s)
    let t = fresh_tmp(ctx)
    c_emit(ctx, "${t} = ring_str_from_cstr(${g});")
    t
}

// ── Eq ───────────────────────────────────────────────────────

// i64 flag (1/0): are the two field values equal under `action`?
fn emit_c_field_eq_flag(mut ctx: CCtx, lhs: Str, rhs: Str, action: FieldAction) -> Str {
    match action {
        FieldAction::Identity => {
            // Tagged (Int/Bool/Unit) → raw compare; heap → ring_str_eq (Str is
            // the only Identity heap type in Eq derivation).
            rt_use(ctx, "ring_str_eq", 2)
            let f = fresh_i64(ctx)
            c_emit(ctx, "if (((intptr_t)${lhs}) & 1) { ${f} = (${lhs} == ${rhs}); } else { ${f} = ring_str_eq(${lhs}, ${rhs}); }")
            f
        },
        FieldAction::FloatIdentity => {
            rt_use(ctx, "ring_unbox_float", 1)
            let f = fresh_i64(ctx)
            c_emit(ctx, "${f} = (ring_unbox_float(${lhs}) == ring_unbox_float(${rhs}));")
            f
        },
        FieldAction::BoolIdentity => {
            let f = fresh_i64(ctx)
            c_emit(ctx, "${f} = (${lhs} == ${rhs});")
            f
        },
        FieldAction::Call { base_dict, extra_dicts } => {
            let r = emit_c_derived_dict_call(
                ctx, base_dict, extra_dicts, [lhs, rhs])
            let f = fresh_i64(ctx)
            c_emit(ctx, "${f} = (RING_UNTAG(${r}) != 0);")
            f
        },
        FieldAction::Tuple { element_actions } => {
            // Short-circuit: first unequal element fails the whole tuple.
            rt_use(ctx, "ring_list_get", 2)
            let f = fresh_i64(ctx)
            c_emit(ctx, "${f} = 0;")
            let fail_lbl = fresh_label(ctx, "teq")
            for i in 0..element_actions.len() {
                match element_actions.get(i) {
                    some(act) => {
                        let le = fresh_tmp(ctx)
                        c_emit(ctx, "${le} = ring_list_get(${lhs}, ${i});")
                        let re = fresh_tmp(ctx)
                        c_emit(ctx, "${re} = ring_list_get(${rhs}, ${i});")
                        let ef = emit_c_field_eq_flag(ctx, le, re, act)
                        c_emit(ctx, "if (!${ef}) goto ${fail_lbl};")
                    },
                    none => {},
                }
            }
            c_emit(ctx, "${f} = 1;")
            c_raw(ctx, "${fail_lbl}:;")
            f
        },
        FieldAction::FnLiteral => {
            let f = fresh_i64(ctx)
            c_emit(ctx, "${f} = 1;")
            f
        },
    }
}

fn emit_c_derived_eq(mut ctx: CCtx, di: DerivedImpl) {
    let type_name = di.type_name
    match di.type_kind {
        TypeKind::StructKind => match di.struct_fields {
            some(fields) => {
                emit_c_struct_eq_fn(ctx, type_name, fields, di.bounds)
                emit_c_ne_fn(ctx, type_name)
                emit_c_derived_trait_dict(ctx, type_name, "Eq")
            },
            none => {},
        },
        TypeKind::EnumKind => match di.enum_variants {
            some(variants) => {
                emit_c_enum_eq_fn(ctx, type_name, variants, di.bounds)
                emit_c_ne_fn(ctx, type_name)
                emit_c_derived_trait_dict(ctx, type_name, "Eq")
            },
            none => {},
        },
    }
}

fn c_find_field_index(field_names: List<Str>, target: Str) -> Int {
    for i in 0..field_names.len() {
        if field_names[i] == target { return i }
    }
    0 - 1
}

fn emit_c_struct_eq_fn(mut ctx: CCtx, type_name: Str, fields: List<DerivedField>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "eq", "Eq", true, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    let struct_info_opt = ctx.struct_types.get(type_name)
    if fields.len() == 0 || struct_info_opt.is_none() {
        c_emit(ctx, "return RING_TRUE;")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let struct_info = struct_info_opt.unwrap()
    for field in fields {
        let field_idx = c_find_field_index(struct_info.field_names, field.name)
        if field_idx < 0 { continue }
        let sfv = fresh_tmp(ctx)
        c_emit(ctx, "${sfv} = ((void**)${scaffold.self_var})[${field_idx}];")
        let ofv = fresh_tmp(ctx)
        c_emit(ctx, "${ofv} = ((void**)${scaffold.other_var})[${field_idx}];")
        let f = emit_c_field_eq_flag(ctx, sfv, ofv, field.action)
        c_emit(ctx, "if (!${f}) return RING_FALSE;")
    }
    c_emit(ctx, "return RING_TRUE;")
    end_c_derived_fn(ctx, scaffold)
}

fn emit_c_enum_eq_fn(mut ctx: CCtx, type_name: Str, variants: List<DerivedVariant>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "eq", "Eq", true, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    let enum_info_opt = ctx.enum_types.get(type_name)
    if enum_info_opt.is_none() {
        c_emit(ctx, "return RING_TRUE;")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let enum_info = enum_info_opt.unwrap()
    let st = fresh_i64(ctx)
    c_emit(ctx, "${st} = *(int64_t*)${scaffold.self_var};")
    let ot = fresh_i64(ctx)
    c_emit(ctx, "${ot} = *(int64_t*)${scaffold.other_var};")

    let mut any_fields = false
    for v in variants {
        if v.fields.len() > 0 { any_fields = true }
    }
    if !any_fields {
        c_emit(ctx, "return RING_BOOL(${st} == ${ot});")
        end_c_derived_fn(ctx, scaffold)
        return
    }

    c_emit(ctx, "if (${st} != ${ot}) return RING_FALSE;")
    let mut vi = 0
    for variant in variants {
        let var_tag = match enum_info.variants.get(variant.name) {
            some(vinfo) => vinfo.tag,
            none => vi,
        }
        vi = vi + 1
        if variant.fields.len() == 0 {
            c_emit(ctx, "if (${st} == ${var_tag}) return RING_TRUE;")
        } else {
            c_emit(ctx, "if (${st} == ${var_tag}) {")
            ctx.indent = ctx.indent + 1
            let mut fi = 0
            for field in variant.fields {
                let sfv = fresh_tmp(ctx)
                c_emit(ctx, "${sfv} = ((void**)${scaffold.self_var})[${fi + 1}];")
                let ofv = fresh_tmp(ctx)
                c_emit(ctx, "${ofv} = ((void**)${scaffold.other_var})[${fi + 1}];")
                let f = emit_c_field_eq_flag(ctx, sfv, ofv, field.action)
                c_emit(ctx, "if (!${f}) return RING_FALSE;")
                fi = fi + 1
            }
            c_emit(ctx, "return RING_TRUE;")
            ctx.indent = ctx.indent - 1
            c_emit(ctx, "}")
        }
    }
    // Default (unreached for well-formed enums): equal.
    c_emit(ctx, "return RING_TRUE;")
    end_c_derived_fn(ctx, scaffold)
}

// ne = !eq, same signature (incl. trailing dict params), pure forwarding.
fn emit_c_ne_fn(mut ctx: CCtx, type_name: Str) {
    let mangled_ne = c_mangle_method(type_name, "ne")
    if ctx.functions.contains_key(mangled_ne) { return }
    let mangled_eq = c_mangle_method(type_name, "eq")
    let eq_fi_opt = ctx.functions.get(mangled_eq)
    if eq_fi_opt.is_none() { return }
    let eq_fi = eq_fi_opt.unwrap()
    let arity = eq_fi.total_params
    let c_name = if is_runtime_symbol(mangled_ne) { "${mangled_ne}__ring" } else { mangled_ne }
    ctx.functions.insert(mangled_ne, CFnInfo { c_name: c_name, total_params: arity })
    let mut no_ev: List<Str> = []
    ctx.fn_evidence_params.insert(mangled_ne, no_ev)
    let mut sig_parts: List<Str> = []
    let mut fwd: List<Str> = []
    for i in 0..arity {
        sig_parts.push("void* p${i}")
        fwd.push("p${i}")
    }
    ctx.fn_protos.push("void* ${c_name}(${sig_parts.join(", ")});")
    let mut def: List<Str> = []
    def.push("void* ${c_name}(${sig_parts.join(", ")}) {")
    def.push("    return RING_BOOL(1 - RING_UNTAG(${eq_fi.c_name}(${fwd.join(", ")})));")
    def.push("}")
    ctx.fn_defs.push(def.join("\n"))
}

// ── Hash ─────────────────────────────────────────────────────

fn emit_c_derived_hash(mut ctx: CCtx, di: DerivedImpl) {
    let type_name = di.type_name
    match di.type_kind {
        TypeKind::StructKind => match di.struct_fields {
            some(fields) => {
                emit_c_struct_hash_fn(ctx, type_name, fields, di.bounds)
            },
            none => {},
        },
        TypeKind::EnumKind => match di.enum_variants {
            some(variants) => {
                emit_c_enum_hash_fn(ctx, type_name, variants, di.bounds)
            },
            none => {},
        },
    }
}

fn emit_c_hash_combine(mut ctx: CCtx, lhs: Str, rhs: Str) -> Str {
    rt_use(ctx, "ring_hash_combine", 2)
    let combined = fresh_i64(ctx)
    c_emit(ctx, "${combined} = ring_hash_combine(${lhs}, ${rhs});")
    combined
}

// Return an unboxed deterministic hash for a field.  Hash derivation emits
// Call/Tuple actions only; the remaining arms are deterministic fail-closed
// fallbacks and never inspect a pointer address.
fn emit_c_field_hash_raw(mut ctx: CCtx, value: Str, action: FieldAction) -> Str {
    match action {
        FieldAction::Call { base_dict, extra_dicts } => {
            let boxed = emit_c_derived_dict_call(
                ctx, base_dict, extra_dicts, [value])
            let raw = fresh_i64(ctx)
            c_emit(ctx, "${raw} = RING_UNTAG(${boxed});")
            raw
        },
        FieldAction::Tuple { element_actions } => {
            rt_use(ctx, "ring_list_get", 2)
            let mut acc = fresh_i64(ctx)
            c_emit(ctx, "${acc} = ${DERIVED_HASH_SEED};")
            for i in 0..element_actions.len() {
                match element_actions.get(i) {
                    some(elem_action) => {
                        let elem = fresh_tmp(ctx)
                        c_emit(ctx, "${elem} = ring_list_get(${value}, ${i});")
                        let elem_hash = emit_c_field_hash_raw(ctx, elem, elem_action)
                        acc = emit_c_hash_combine(ctx, acc, elem_hash)
                    },
                    none => {},
                }
            }
            acc
        },
        FieldAction::Identity => {
            let raw = fresh_i64(ctx)
            c_emit(ctx, "${raw} = 0;")
            raw
        },
        FieldAction::FloatIdentity => {
            let raw = fresh_i64(ctx)
            c_emit(ctx, "${raw} = 0;")
            raw
        },
        FieldAction::BoolIdentity => {
            let raw = fresh_i64(ctx)
            c_emit(ctx, "${raw} = 0;")
            raw
        },
        FieldAction::FnLiteral => {
            let raw = fresh_i64(ctx)
            c_emit(ctx, "${raw} = 0;")
            raw
        },
    }
}

fn emit_c_struct_hash_fn(mut ctx: CCtx, type_name: Str, fields: List<DerivedField>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "hash", "Hash", false, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    // Register the dictionary after the direct method is known but before its
    // body resolves field evidence. Recursive Hash fields can now call this
    // singleton instead of falling through to a nonexistent builtin dict.
    emit_c_derived_trait_dict(ctx, type_name, "Hash")
    let struct_info_opt = ctx.struct_types.get(type_name)
    let mut acc = fresh_i64(ctx)
    c_emit(ctx, "${acc} = ${DERIVED_HASH_SEED};")
    match struct_info_opt {
        some(struct_info) => {
            for field in fields {
                let field_idx = c_find_field_index(struct_info.field_names, field.name)
                if field_idx >= 0 {
                    let field_value = fresh_tmp(ctx)
                    c_emit(ctx, "${field_value} = ((void**)${scaffold.self_var})[${field_idx}];")
                    let field_hash = emit_c_field_hash_raw(ctx, field_value, field.action)
                    acc = emit_c_hash_combine(ctx, acc, field_hash)
                }
            }
        },
        none => {},
    }
    c_emit(ctx, "return RING_INT(${acc});")
    end_c_derived_fn(ctx, scaffold)
}

fn emit_c_enum_hash_fn(mut ctx: CCtx, type_name: Str, variants: List<DerivedVariant>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "hash", "Hash", false, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    emit_c_derived_trait_dict(ctx, type_name, "Hash")
    let enum_info_opt = ctx.enum_types.get(type_name)
    if enum_info_opt.is_none() {
        c_emit(ctx, "return RING_INT(${DERIVED_HASH_SEED});")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let enum_info = enum_info_opt.unwrap()
    let tag = fresh_i64(ctx)
    c_emit(ctx, "${tag} = *(int64_t*)${scaffold.self_var};")
    let mut vi = 0
    for variant in variants {
        let runtime_tag = match enum_info.variants.get(variant.name) {
            some(vinfo) => vinfo.tag,
            none => vi,
        }
        vi = vi + 1
        c_emit(ctx, "if (${tag} == ${runtime_tag}) {")
        ctx.indent = ctx.indent + 1
        let seed = fresh_i64(ctx)
        c_emit(ctx, "${seed} = ${DERIVED_HASH_SEED};")
        let discriminator = fresh_i64(ctx)
        c_emit(ctx, "${discriminator} = ${variant.discriminator};")
        let mut acc = emit_c_hash_combine(ctx, seed, discriminator)
        let mut fi = 0
        for field in variant.fields {
            let field_value = fresh_tmp(ctx)
            c_emit(ctx, "${field_value} = ((void**)${scaffold.self_var})[${fi + 1}];")
            let field_hash = emit_c_field_hash_raw(ctx, field_value, field.action)
            acc = emit_c_hash_combine(ctx, acc, field_hash)
            fi = fi + 1
        }
        c_emit(ctx, "return RING_INT(${acc});")
        ctx.indent = ctx.indent - 1
        c_emit(ctx, "}")
    }
    c_emit(ctx, "return RING_INT(${DERIVED_HASH_SEED});")
    end_c_derived_fn(ctx, scaffold)
}

// ── Ord ──────────────────────────────────────────────────────

fn emit_c_derived_ord(mut ctx: CCtx, di: DerivedImpl) {
    let type_name = di.type_name
    match di.type_kind {
        TypeKind::StructKind => match di.struct_fields {
            some(fields) => {
                emit_c_struct_cmp_fn(ctx, type_name, fields, di.bounds)
                emit_c_derived_trait_dict(ctx, type_name, "Ord")
            },
            none => {},
        },
        TypeKind::EnumKind => match di.enum_variants {
            some(variants) => {
                emit_c_enum_cmp_fn(ctx, type_name, variants, di.bounds)
                emit_c_derived_trait_dict(ctx, type_name, "Ord")
            },
            none => {},
        },
    }
}

// Boxed Int (-1/0/1) comparing two field values under `action`.
fn emit_c_field_cmp_val(mut ctx: CCtx, lhs: Str, rhs: Str, action: FieldAction) -> Str {
    match action {
        FieldAction::Identity => {
            // Tagged → signed compare of untagged values; heap → the runtime
            // Str cmp helper (null env).
            rt_use(ctx, "ring_cl_cmp_str", 3)
            let li = fresh_i64(ctx)
            let ri = fresh_i64(ctx)
            let cv = fresh_tmp(ctx)
            c_emit(ctx, "if (((intptr_t)${lhs}) & 1) { ${li} = RING_UNTAG(${lhs}); ${ri} = RING_UNTAG(${rhs}); ${cv} = RING_INT(${li} < ${ri} ? -1 : (${li} > ${ri} ? 1 : 0)); } else { ${cv} = ring_cl_cmp_str(RING_UNIT, ${lhs}, ${rhs}); }")
            cv
        },
        FieldAction::FloatIdentity => {
            rt_use(ctx, "ring_unbox_float", 1)
            let ld = fresh_dbl(ctx)
            let rd = fresh_dbl(ctx)
            c_emit(ctx, "${ld} = ring_unbox_float(${lhs});")
            c_emit(ctx, "${rd} = ring_unbox_float(${rhs});")
            let cv = fresh_tmp(ctx)
            c_emit(ctx, "${cv} = RING_INT(${ld} < ${rd} ? -1 : (${ld} > ${rd} ? 1 : 0));")
            cv
        },
        FieldAction::BoolIdentity => {
            // Tagged like Int — LLVM routes BoolIdentity through the same
            // identity cmp; both operands are tagged so only that leg runs.
            let li = fresh_i64(ctx)
            let ri = fresh_i64(ctx)
            let cv = fresh_tmp(ctx)
            c_emit(ctx, "${li} = RING_UNTAG(${lhs});")
            c_emit(ctx, "${ri} = RING_UNTAG(${rhs});")
            c_emit(ctx, "${cv} = RING_INT(${li} < ${ri} ? -1 : (${li} > ${ri} ? 1 : 0));")
            cv
        },
        FieldAction::Call { base_dict, extra_dicts } => {
            emit_c_derived_dict_call(ctx, base_dict, extra_dicts, [lhs, rhs])
        },
        FieldAction::Tuple { element_actions } => {
            rt_use(ctx, "ring_list_get", 2)
            let cv = fresh_tmp(ctx)
            c_emit(ctx, "${cv} = RING_INT(0);")
            let done_lbl = fresh_label(ctx, "tcmp")
            let n = element_actions.len()
            for i in 0..n {
                match element_actions.get(i) {
                    some(act) => {
                        let le = fresh_tmp(ctx)
                        c_emit(ctx, "${le} = ring_list_get(${lhs}, ${i});")
                        let re = fresh_tmp(ctx)
                        c_emit(ctx, "${re} = ring_list_get(${rhs}, ${i});")
                        let ecv = emit_c_field_cmp_val(ctx, le, re, act)
                        c_emit(ctx, "${cv} = ${ecv};")
                        if i < n - 1 {
                            c_emit(ctx, "if (RING_UNTAG(${cv}) != 0) goto ${done_lbl};")
                        }
                    },
                    none => {},
                }
            }
            c_raw(ctx, "${done_lbl}:;")
            cv
        },
        FieldAction::FnLiteral => {
            let cv = fresh_tmp(ctx)
            c_emit(ctx, "${cv} = RING_INT(0);")
            cv
        },
    }
}

fn emit_c_struct_cmp_fn(mut ctx: CCtx, type_name: Str, fields: List<DerivedField>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "cmp", "Ord", true, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    let struct_info_opt = ctx.struct_types.get(type_name)
    if fields.len() == 0 || struct_info_opt.is_none() {
        c_emit(ctx, "return RING_INT(0);")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let struct_info = struct_info_opt.unwrap()
    let n = fields.len()
    for fi in 0..n {
        match fields.get(fi) {
            some(field) => {
                let field_idx = c_find_field_index(struct_info.field_names, field.name)
                if field_idx >= 0 {
                    let sfv = fresh_tmp(ctx)
                    c_emit(ctx, "${sfv} = ((void**)${scaffold.self_var})[${field_idx}];")
                    let ofv = fresh_tmp(ctx)
                    c_emit(ctx, "${ofv} = ((void**)${scaffold.other_var})[${field_idx}];")
                    let cv = emit_c_field_cmp_val(ctx, sfv, ofv, field.action)
                    if fi < n - 1 {
                        c_emit(ctx, "if (RING_UNTAG(${cv}) != 0) return ${cv};")
                    } else {
                        c_emit(ctx, "return ${cv};")
                    }
                }
            },
            none => {},
        }
    }
    // Fallback (all field indices missing — cannot happen for well-formed input).
    c_emit(ctx, "return RING_INT(0);")
    end_c_derived_fn(ctx, scaffold)
}

fn emit_c_enum_cmp_fn(mut ctx: CCtx, type_name: Str, variants: List<DerivedVariant>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "cmp", "Ord", true, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    let enum_info_opt = ctx.enum_types.get(type_name)
    if enum_info_opt.is_none() {
        c_emit(ctx, "return RING_INT(0);")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let enum_info = enum_info_opt.unwrap()
    let st = fresh_i64(ctx)
    c_emit(ctx, "${st} = *(int64_t*)${scaffold.self_var};")
    let ot = fresh_i64(ctx)
    c_emit(ctx, "${ot} = *(int64_t*)${scaffold.other_var};")
    c_emit(ctx, "if (${st} != ${ot}) return RING_INT(${st} < ${ot} ? -1 : 1);")
    let mut vi = 0
    for variant in variants {
        let var_tag = match enum_info.variants.get(variant.name) {
            some(vinfo) => vinfo.tag,
            none => vi,
        }
        vi = vi + 1
        if variant.fields.len() == 0 {
            c_emit(ctx, "if (${st} == ${var_tag}) return RING_INT(0);")
        } else {
            c_emit(ctx, "if (${st} == ${var_tag}) {")
            ctx.indent = ctx.indent + 1
            let n = variant.fields.len()
            for fi in 0..n {
                match variant.fields.get(fi) {
                    some(field) => {
                        let sfv = fresh_tmp(ctx)
                        c_emit(ctx, "${sfv} = ((void**)${scaffold.self_var})[${fi + 1}];")
                        let ofv = fresh_tmp(ctx)
                        c_emit(ctx, "${ofv} = ((void**)${scaffold.other_var})[${fi + 1}];")
                        let cv = emit_c_field_cmp_val(ctx, sfv, ofv, field.action)
                        if fi < n - 1 {
                            c_emit(ctx, "if (RING_UNTAG(${cv}) != 0) return ${cv};")
                        } else {
                            c_emit(ctx, "return ${cv};")
                        }
                    },
                    none => {},
                }
            }
            ctx.indent = ctx.indent - 1
            c_emit(ctx, "}")
        }
    }
    c_emit(ctx, "return RING_INT(0);")
    end_c_derived_fn(ctx, scaffold)
}

// ── Clone ────────────────────────────────────────────────────
// Clone under Perceus RC = ring_dup (RC increment; values are immutable).

fn emit_c_derived_clone(mut ctx: CCtx, di: DerivedImpl) {
    emit_c_clone_fn(ctx, di.type_name, di.bounds)
    emit_c_derived_trait_dict(ctx, di.type_name, "Clone")
}

// The clone SIGNATURE must match the checker-registered scheme: derive.ring
// registers clone with the impl's [T: Clone] bounds, so call sites pass the
// dicts.  The LLVM backend declares clone with empty bounds and survives on
// call-arity overflow being silently harmless — clang makes that a hard
// error, so the C backend declares the dict params (body ignores them:
// clone = shallow ring_dup).  Recorded in worker_feedback.
fn emit_c_clone_fn(mut ctx: CCtx, type_name: Str, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "clone", "Clone", false, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    rt_use(ctx, "ring_dup", 1)
    c_emit(ctx, "ring_dup(${scaffold.self_var});")
    c_emit(ctx, "return ${scaffold.self_var};")
    end_c_derived_fn(ctx, scaffold)
}

// ── Debug ────────────────────────────────────────────────────
// "Point { x: 1, y: 2 }" / "Red" / "Circle(7)" via the runtime SB shims.

fn emit_c_derived_debug(mut ctx: CCtx, di: DerivedImpl) {
    let type_name = di.type_name
    // #196: only emit the trait dict when a debug method was generated.
    let mut emitted = false
    match di.type_kind {
        TypeKind::StructKind => match di.struct_fields {
            some(fields) => {
                emit_c_struct_debug_fn(ctx, type_name, fields, di.bounds)
                emitted = true
            },
            none => {},
        },
        TypeKind::EnumKind => match di.enum_variants {
            some(variants) => {
                emit_c_enum_debug_fn(ctx, type_name, variants, di.bounds)
                emitted = true
            },
            none => {},
        },
    }
    if emitted {
        emit_c_derived_trait_dict(ctx, type_name, "Debug")
    }
}

// Fresh Str with the debug rendering of one field value.
fn emit_c_debug_field_str(mut ctx: CCtx, v: Str, action: FieldAction) -> Str {
    match action {
        FieldAction::Identity => {
            // Tagged → Int rendering; heap → it IS a Str (dup so the caller
            // can drop uniformly).
            rt_use(ctx, "ring_int_to_str", 1)
            rt_use(ctx, "ring_dup", 1)
            let s = fresh_tmp(ctx)
            c_emit(ctx, "if (((intptr_t)${v}) & 1) { ${s} = ring_int_to_str(RING_UNTAG(${v})); } else { ring_dup(${v}); ${s} = ${v}; }")
            s
        },
        FieldAction::FloatIdentity => {
            rt_use(ctx, "ring_unbox_float", 1)
            rt_use(ctx, "ring_float_to_str", 1)
            let s = fresh_tmp(ctx)
            c_emit(ctx, "${s} = ring_float_to_str(ring_unbox_float(${v}));")
            s
        },
        FieldAction::BoolIdentity => {
            rt_use(ctx, "ring_bool_to_str", 1)
            let s = fresh_tmp(ctx)
            c_emit(ctx, "${s} = ring_bool_to_str(RING_UNTAG(${v}));")
            s
        },
        FieldAction::Call { base_dict, extra_dicts } => {
            emit_c_derived_dict_call(ctx, base_dict, extra_dicts, [v])
        },
        FieldAction::Tuple { element_actions } => {
            if element_actions.len() == 0 {
                return c_derived_str_lit(ctx, "()")
            }
            rt_use(ctx, "ring_sb_new", 0)
            rt_use(ctx, "ring_sb_add", 2)
            rt_use(ctx, "ring_sb_to_str", 1)
            rt_use(ctx, "ring_drop", 1)
            rt_use(ctx, "ring_list_get", 2)
            let sb = fresh_tmp(ctx)
            c_emit(ctx, "${sb} = ring_sb_new();")
            emit_c_sb_add_lit(ctx, sb, "(")
            for i in 0..element_actions.len() {
                match element_actions.get(i) {
                    some(act) => {
                        if i > 0 {
                            emit_c_sb_add_lit(ctx, sb, ", ")
                        }
                        let elem = fresh_tmp(ctx)
                        c_emit(ctx, "${elem} = ring_list_get(${v}, ${i});")
                        let es = emit_c_debug_field_str(ctx, elem, act)
                        c_emit(ctx, "ring_sb_add(${sb}, ${es});")
                        c_emit(ctx, "ring_drop(${es});")
                    },
                    none => {},
                }
            }
            emit_c_sb_add_lit(ctx, sb, ")")
            let res = fresh_tmp(ctx)
            c_emit(ctx, "${res} = ring_sb_to_str(${sb});")
            c_emit(ctx, "ring_drop(${sb});")
            res
        },
        FieldAction::FnLiteral => c_derived_str_lit(ctx, "<fn>"),
    }
}

// Append a fresh string literal to a SB and drop the literal.
fn emit_c_sb_add_lit(mut ctx: CCtx, sb: Str, s: Str) {
    rt_use(ctx, "ring_sb_add", 2)
    rt_use(ctx, "ring_drop", 1)
    let lit = c_derived_str_lit(ctx, s)
    c_emit(ctx, "ring_sb_add(${sb}, ${lit});")
    c_emit(ctx, "ring_drop(${lit});")
}

fn emit_c_struct_debug_fn(mut ctx: CCtx, type_name: Str, fields: List<DerivedField>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "debug", "Debug", false, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    let struct_info_opt = ctx.struct_types.get(type_name)
    if fields.len() == 0 || struct_info_opt.is_none() {
        let lit = c_derived_str_lit(ctx, type_name)
        c_emit(ctx, "return ${lit};")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let struct_info = struct_info_opt.unwrap()
    rt_use(ctx, "ring_sb_new", 0)
    rt_use(ctx, "ring_sb_add", 2)
    rt_use(ctx, "ring_sb_to_str", 1)
    rt_use(ctx, "ring_drop", 1)
    let sb = fresh_tmp(ctx)
    c_emit(ctx, "${sb} = ring_sb_new();")
    emit_c_sb_add_lit(ctx, sb, "${type_name} { ")
    let mut first = true
    for field in fields {
        let field_idx = c_find_field_index(struct_info.field_names, field.name)
        if field_idx >= 0 {
            if first {
                emit_c_sb_add_lit(ctx, sb, "${field.name}: ")
            } else {
                emit_c_sb_add_lit(ctx, sb, ", ${field.name}: ")
            }
            first = false
            let fv = fresh_tmp(ctx)
            c_emit(ctx, "${fv} = ((void**)${scaffold.self_var})[${field_idx}];")
            let sv = emit_c_debug_field_str(ctx, fv, field.action)
            c_emit(ctx, "ring_sb_add(${sb}, ${sv});")
            c_emit(ctx, "ring_drop(${sv});")
        }
    }
    emit_c_sb_add_lit(ctx, sb, " }")
    let res = fresh_tmp(ctx)
    c_emit(ctx, "${res} = ring_sb_to_str(${sb});")
    c_emit(ctx, "ring_drop(${sb});")
    c_emit(ctx, "return ${res};")
    end_c_derived_fn(ctx, scaffold)
}

fn emit_c_enum_debug_fn(mut ctx: CCtx, type_name: Str, variants: List<DerivedVariant>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "debug", "Debug", false, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    let enum_info_opt = ctx.enum_types.get(type_name)
    if enum_info_opt.is_none() {
        let lit = c_derived_str_lit(ctx, type_name)
        c_emit(ctx, "return ${lit};")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let enum_info = enum_info_opt.unwrap()
    let tag = fresh_i64(ctx)
    c_emit(ctx, "${tag} = *(int64_t*)${scaffold.self_var};")
    let mut vi = 0
    for variant in variants {
        let var_tag = match enum_info.variants.get(variant.name) {
            some(vinfo) => vinfo.tag,
            none => vi,
        }
        vi = vi + 1
        c_emit(ctx, "if (${tag} == ${var_tag}) {")
        ctx.indent = ctx.indent + 1
        if variant.fields.len() == 0 {
            let lit = c_derived_str_lit(ctx, variant.name)
            c_emit(ctx, "return ${lit};")
        } else {
            let res = emit_c_enum_variant_debug_str(ctx, scaffold.self_var, variant)
            c_emit(ctx, "return ${res};")
        }
        ctx.indent = ctx.indent - 1
        c_emit(ctx, "}")
    }
    // Default: type name (unreached for well-formed enums).
    let dflt = c_derived_str_lit(ctx, type_name)
    c_emit(ctx, "return ${dflt};")
    end_c_derived_fn(ctx, scaffold)
}

fn emit_c_enum_variant_debug_str(mut ctx: CCtx, self_var: Str, variant: DerivedVariant) -> Str {
    rt_use(ctx, "ring_sb_new", 0)
    rt_use(ctx, "ring_sb_add", 2)
    rt_use(ctx, "ring_sb_to_str", 1)
    rt_use(ctx, "ring_drop", 1)
    let sb = fresh_tmp(ctx)
    c_emit(ctx, "${sb} = ring_sb_new();")
    if variant.has_named_fields {
        emit_c_sb_add_lit(ctx, sb, "${variant.name} { ")
    } else {
        emit_c_sb_add_lit(ctx, sb, "${variant.name}(")
    }
    for fi in 0..variant.fields.len() {
        match variant.fields.get(fi) {
            some(field) => {
                if fi > 0 {
                    emit_c_sb_add_lit(ctx, sb, ", ")
                }
                if variant.has_named_fields {
                    emit_c_sb_add_lit(ctx, sb, "${field.name}: ")
                }
                let fv = fresh_tmp(ctx)
                c_emit(ctx, "${fv} = ((void**)${self_var})[${fi + 1}];")
                let sv = emit_c_debug_field_str(ctx, fv, field.action)
                c_emit(ctx, "ring_sb_add(${sb}, ${sv});")
                c_emit(ctx, "ring_drop(${sv});")
            },
            none => {},
        }
    }
    if variant.has_named_fields {
        emit_c_sb_add_lit(ctx, sb, " }")
    } else {
        emit_c_sb_add_lit(ctx, sb, ")")
    }
    let res = fresh_tmp(ctx)
    c_emit(ctx, "${res} = ring_sb_to_str(${sb});")
    c_emit(ctx, "ring_drop(${sb});")
    res
}

// ── Json ────────────────────────────────────────────────────
// Historical JSON shape: structs are objects in declaration order; enums are
// objects beginning with the textual `_tag`, followed by named fields or
// positional `_0`, `_1`, ... fields. Every value is encoded through ordinary
// Json dictionary evidence, never through runtime representation guessing.

fn emit_c_derived_json(mut ctx: CCtx, di: DerivedImpl) {
    match di.type_kind {
        TypeKind::StructKind => match di.struct_fields {
            some(fields) => emit_c_struct_json_fn(ctx, di.type_name, fields, di.bounds),
            none => {}
        },
        TypeKind::EnumKind => match di.enum_variants {
            some(variants) => emit_c_enum_json_fn(ctx, di.type_name, variants, di.bounds),
            none => {}
        }
    }
}

// Json SCC prepass. The derive pass has already registered the whole nominal
// SCC in TypeEnv; mirror that atomicity in C registries before any field action
// can ask for a peer dictionary.
fn predeclare_c_json_derived_impls(
    mut ctx: CCtx, derived_impls: List<DerivedImpl>
) {
    for di in derived_impls {
        if di.trait_name == "Json" {
            predeclare_c_derived_fn(
                ctx, di.type_name, "to_json", false, di.bounds)
            predeclare_c_derived_trait_dict(ctx, di.type_name, "Json")
        }
    }
    // All builders are known before any getter selects its route.
    for di in derived_impls {
        if di.trait_name == "Json" {
            let _getter = ensure_c_dict_getter(
                ctx, trait_dict_name(di.type_name, "Json"))
        }
    }
}

fn emit_c_json_field_str(mut ctx: CCtx, value: Str, action: FieldAction) -> Str {
    match action {
        FieldAction::Call { base_dict, extra_dicts } =>
            emit_c_derived_dict_call(ctx, base_dict, extra_dicts, [value]),
        // Json derivation only produces Call actions. Keep the backend
        // fail-loud if a future derive rule violates that evidence boundary.
        _ => {
            rt_use(ctx, "ring_panic", 1)
            let msg = c_derived_str_lit(ctx, "invalid Json derive field action")
            c_emit(ctx, "ring_panic(${msg});")
            c_derived_str_lit(ctx, "null")
        }
    }
}

fn emit_c_struct_json_fn(mut ctx: CCtx, type_name: Str, fields: List<DerivedField>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "to_json", "Json", false, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    emit_c_derived_trait_dict(ctx, type_name, "Json")
    let struct_info_opt = ctx.struct_types.get(type_name)
    if struct_info_opt.is_none() {
        rt_use(ctx, "ring_panic", 1)
        let msg = c_derived_str_lit(ctx, "Json derive missing struct layout")
        c_emit(ctx, "return ring_panic(${msg});")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let struct_info = struct_info_opt.unwrap()
    rt_use(ctx, "ring_sb_new", 0)
    rt_use(ctx, "ring_sb_add", 2)
    rt_use(ctx, "ring_sb_to_str", 1)
    rt_use(ctx, "ring_drop", 1)
    let sb = fresh_tmp(ctx)
    c_emit(ctx, "${sb} = ring_sb_new();")
    emit_c_sb_add_lit(ctx, sb, "{")
    let mut first = true
    for field in fields {
        let field_idx = c_find_field_index(struct_info.field_names, field.name)
        if field_idx < 0 {
            rt_use(ctx, "ring_panic", 1)
            let msg = c_derived_str_lit(ctx, "Json derive field is absent from struct layout")
            c_emit(ctx, "return ring_panic(${msg});")
        } else {
            if first {
                emit_c_sb_add_lit(ctx, sb, "\"${field.name}\":")
                first = false
            } else {
                emit_c_sb_add_lit(ctx, sb, ",\"${field.name}\":")
            }
            let field_value = fresh_tmp(ctx)
            c_emit(ctx, "${field_value} = ((void**)${scaffold.self_var})[${field_idx}];")
            let encoded = emit_c_json_field_str(ctx, field_value, field.action)
            c_emit(ctx, "ring_sb_add(${sb}, ${encoded});")
            c_emit(ctx, "ring_drop(${encoded});")
        }
    }
    emit_c_sb_add_lit(ctx, sb, "}")
    let result = fresh_tmp(ctx)
    c_emit(ctx, "${result} = ring_sb_to_str(${sb});")
    c_emit(ctx, "ring_drop(${sb});")
    c_emit(ctx, "return ${result};")
    end_c_derived_fn(ctx, scaffold)
}

fn emit_c_enum_json_fn(mut ctx: CCtx, type_name: Str, variants: List<DerivedVariant>, bounds: List<TraitBound>) {
    let scaffold_opt = begin_c_derived_fn(ctx, type_name, "to_json", "Json", false, bounds)
    if scaffold_opt.is_none() { return }
    let scaffold = scaffold_opt.unwrap()
    emit_c_derived_trait_dict(ctx, type_name, "Json")
    let enum_info_opt = ctx.enum_types.get(type_name)
    if enum_info_opt.is_none() {
        rt_use(ctx, "ring_panic", 1)
        let msg = c_derived_str_lit(ctx, "Json derive missing enum layout")
        c_emit(ctx, "return ring_panic(${msg});")
        end_c_derived_fn(ctx, scaffold)
        return
    }
    let enum_info = enum_info_opt.unwrap()
    let tag = fresh_i64(ctx)
    c_emit(ctx, "${tag} = *(int64_t*)${scaffold.self_var};")
    for variant in variants {
        let runtime_tag = match enum_info.variants.get(variant.name) {
            some(vinfo) => vinfo.tag,
            none => panic("C codegen invariant: Json derive variant '${type_name}::${variant.name}' is absent from enum metadata")
        }
        c_emit(ctx, "if (${tag} == ${runtime_tag}) {")
        ctx.indent = ctx.indent + 1
        rt_use(ctx, "ring_sb_new", 0)
        rt_use(ctx, "ring_sb_add", 2)
        rt_use(ctx, "ring_sb_to_str", 1)
        rt_use(ctx, "ring_drop", 1)
        let sb = fresh_tmp(ctx)
        c_emit(ctx, "${sb} = ring_sb_new();")
        emit_c_sb_add_lit(ctx, sb, "{\"_tag\":\"${variant.name}\"")
        for field_index in 0..variant.fields.len() {
            match variant.fields.get(field_index) {
                some(field) => {
                    emit_c_sb_add_lit(ctx, sb, ",\"${field.name}\":")
                    let field_value = fresh_tmp(ctx)
                    c_emit(ctx, "${field_value} = ((void**)${scaffold.self_var})[${field_index + 1}];")
                    let encoded = emit_c_json_field_str(ctx, field_value, field.action)
                    c_emit(ctx, "ring_sb_add(${sb}, ${encoded});")
                    c_emit(ctx, "ring_drop(${encoded});")
                },
                none => {}
            }
        }
        emit_c_sb_add_lit(ctx, sb, "}")
        let result = fresh_tmp(ctx)
        c_emit(ctx, "${result} = ring_sb_to_str(${sb});")
        c_emit(ctx, "ring_drop(${sb});")
        c_emit(ctx, "return ${result};")
        ctx.indent = ctx.indent - 1
        c_emit(ctx, "}")
    }
    rt_use(ctx, "ring_panic", 1)
    let msg = c_derived_str_lit(ctx, "invalid enum tag in Json derive")
    c_emit(ctx, "return ring_panic(${msg});")
    end_c_derived_fn(ctx, scaffold)
}

// ── derived trait dict ───────────────────────────────────────
// Build fn + memoised getter for a derived impl's dict.  A user-written impl
// dict (pre-registered in the forward pass) wins — skip.

fn emit_c_derived_trait_dict(mut ctx: CCtx, target_type: Str, trait_name: Str) {
    let dict_name = trait_dict_name(target_type, trait_name)
    let method_order_opt = ctx.trait_method_order.get(trait_name)
    if method_order_opt.is_none() { return }
    let method_order = method_order_opt.unwrap()
    let method_count = method_order.len()
    if method_count == 0 { return }

    let build_fn_name = "ring_dict_build_${c_symbol_fragment(dict_name)}"
    if ctx.emitted_fns.contains(build_fn_name) { return }
    ctx.emitted_fns.insert(build_fn_name)
    if !ctx.dict_build_fns.contains(dict_name) {
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
                emit_c_dict_method_slot(ctx, target_type, trait_name, method_name, dict, i)
            },
            none => {},
        }
    }
    c_emit(ctx, "return ${dict};")
    c_pop_fn(ctx, build_fn_name, "void", saved)

    let _g = ensure_c_dict_getter(ctx, dict_name)
}

fn predeclare_c_derived_trait_dict(
    mut ctx: CCtx, target_type: Str, trait_name: Str
) {
    let method_order = match ctx.trait_method_order.get(trait_name) {
        some(found) => found,
        none => panic("C codegen invariant: derived trait '${trait_name}' has no method metadata")
    }
    if method_order.len() == 0 {
        panic("C codegen invariant: derived trait '${trait_name}' has an empty dictionary")
    }
    let dict_name = trait_dict_name(target_type, trait_name)
    if !ctx.dict_build_fns.contains(dict_name) {
        ctx.dict_build_fns.insert(dict_name)
        ctx.fn_protos.push(
            "void* ring_dict_build_${c_symbol_fragment(dict_name)}(void);")
    }
}
