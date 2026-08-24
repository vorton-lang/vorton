use types::{Type, EffectRow, type_to_string, effect_row_to_string, nominal_display_name}
use ast::{Program, UseDecl, TypeParam, Span}
use hir::{HProgram, HDecl, HParam, module_item_identity, is_module_item_identity}
use diagnostics::{Severity, DiagnosticContext, CollectingSink, Diagnostic, new_collecting_sink, make_diag}
use formatter::{format_human, format_llm}
use env::{TypeEnv}
use checker::{check_module}
use codegen_c::{generate_c_project}
use resolver::{ModuleGraph, ModuleId, module_key, module_prefix,
    build_module_graph}
use exports::{ModuleExports, extract_exports}
use perceus::{perceus_transform, perceus_transform_mutated}
use verify_rc::{RcFinding, verify_rc_program, rc_fatal_count, format_rc_findings}
use codes::{E0708}
use infer_helpers::{is_value_type}
use phase_timing::{
    PhaseTiming, PHASE_PROJECT_MODULE_LOAD_PARSE,
    PHASE_TYPE_EFFECT_CHECK_LOWER, PHASE_RESOURCE_PLAN_VERIFY}

pub struct CompileProjectResult {
    pub success: Bool
}

// ============================================================
// Shared resolve → parse → check pipeline
// ============================================================

struct CompilePhaseResult {
    graph: ModuleGraph,
    module_asts: Map<Str, Program>,
    module_hirs: Map<Str, HProgram>,
    module_exports_map: Map<Str, ModuleExports>,
    extern_forward_bridges: Map<Str, Str>
}

// Project checking produces one already-dict-lowered HProgram per module.
// Keep builtin derived bodies in the first deterministic physical carrier so
// project codegen observes the same builtin-before-user order as single-file
// codegen without per-module synthesis or backend deduplication.
struct ProjectRingFnCandidate {
    module_key: Str,
    identity: Str,
    leaf: Str,
    signature: Str
}

struct ProjectExternForward {
    module_key: Str,
    identity: Str,
    abi_name: Str,
    signature: Str,
    span: Span
}

fn project_identity_leaf(identity: Str) -> Str {
    let inline_parts = identity.split("::")
    let inline_leaf = inline_parts.get(inline_parts.len() - 1).unwrap_or(identity)
    let file_parts = inline_leaf.split("$$_")
    file_parts.get(file_parts.len() - 1).unwrap_or(inline_leaf)
}

// Conservative compatibility key for an intentional raw ExternFn forward.
// Resolved nominal identities remain visible in type_to_string, while named
// type parameters allow the same explicit generic signature to match across
// independently checked modules. Bounded generics are deliberately not
// bridged until their constraints can be compared structurally.
fn project_callable_signature(
    type_params: List<TypeParam>, params: List<HParam>,
    return_type: Type, effects: EffectRow
) -> Str? {
    let mut tparams: List<Str> = []
    for tp in type_params {
        if tp.bounds.len() > 0 { return none }
        tparams.push(tp.name)
    }
    let mut param_types: List<Str> = []
    for p in params {
        // A normal Ring `mut` value-type parameter uses the CELL ABI, while a
        // genuine ExternFn does not register caller pre-boxing metadata. Until
        // the checker can mark a declaration as an internal forward explicitly,
        // do not bridge this ABI-sensitive shape. Mutable struct/context params
        // are reference-shaped and safe to compare exactly below.
        if p.is_mutable && is_value_type(p.ty) { return none }
        let mutability = if p.is_mutable { "mut " } else { "" }
        param_types.push("${mutability}${type_to_string(p.ty)}")
    }
    some("<${tparams.join(",")}>(${param_types.join(",")})->${type_to_string(return_type)} with {${effect_row_to_string(effects)}}")
}

fn collect_project_ring_candidates(
    module_key_: Str, decls: List<HDecl>, mut out: List<ProjectRingFnCandidate>
) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, type_params, params, return_type, effects, is_pub, .. } => {
                // Raw prelude functions are repeated in every HProgram. Only a
                // canonical project definition may satisfy a project forward.
                if is_pub && is_module_item_identity(name) {
                    match project_callable_signature(type_params, params, return_type, effects) {
                        some(signature) => out.push(ProjectRingFnCandidate {
                            module_key: module_key_, identity: name,
                            leaf: project_identity_leaf(name), signature: signature
                        }),
                        none => {}
                    }
                }
            },
            HDecl::ModBlock { decls: nested, .. } => {
                collect_project_ring_candidates(module_key_, nested, out)
            },
            _ => {}
        }
    }
}

fn collect_project_extern_forwards(
    module_key_: Str, module_prefix_: Str, decls: List<HDecl>,
    mut out: List<ProjectExternForward>
) {
    for decl in decls {
        match decl {
            HDecl::ExternFn { name, abi_name, type_params, params, return_type, effects, span, .. } => {
                // Prelude externs use compiler-intrinsic identities and inline
                // externs have an additional `::` component. Only this file
                // module's exact top-level declaration may cycle-break.
                if name == module_item_identity(module_prefix_, abi_name) {
                    match project_callable_signature(type_params, params, return_type, effects) {
                        some(signature) => out.push(ProjectExternForward {
                            module_key: module_key_, identity: name,
                            abi_name: abi_name, signature: signature, span: span
                        }),
                        none => {}
                    }
                }
            },
            HDecl::ModBlock { decls: nested, .. } => {
                collect_project_extern_forwards(module_key_, module_prefix_, nested, out)
            },
            _ => {}
        }
    }
}

fn module_directly_depends_on(graph: ModuleGraph, from_key: Str, target_key: Str) -> Bool {
    match graph.dependencies.get(from_key) {
        some(deps) => {
            for dep in deps { if dep == target_key { return true } }
            false
        },
        none => false
    }
}

fn report_extern_forward_ambiguity(
    graph: ModuleGraph, forward: ProjectExternForward,
    candidates: List<ProjectRingFnCandidate>, error_format: Str
) {
    let mut names: List<Str> = []
    for candidate in candidates { names.push(nominal_display_name(candidate.identity)) }
    names.sort()
    let mut sink = new_collecting_sink()
    sink.report(make_diag(
        E0708, Severity::SevError,
        "Ambiguous project extern forward '${forward.abi_name}': matching public Ring definitions are ${names.join(", ")}",
        forward.span,
        DiagnosticContext::OtherContext { detail: some("extern forward requires one exact project implementation") }
    ))
    let mod_file = match graph.modules.get(forward.module_key) {
        some(module_) => module_.file_path,
        none => ""
    }
    if error_format == "llm" {
        eprintln(format_llm(sink.diagnostics(), mod_file))
    } else {
        let source = if mod_file.len() > 0 { read_file(mod_file) } else { "" }
        eprintln(format_human(sink.diagnostics(), source))
    }
}

// A bridge is evidence-based rather than a leaf-name fallback. The provider
// must directly depend on the declaration module (the deliberate cycle-break
// shape), expose one public canonical Ring function, and match its full
// resolved signature. Zero matches remains real FFI; ambiguity is an error.
fn build_project_extern_forward_bridges(
    graph: ModuleGraph, module_hirs: Map<Str, HProgram>, error_format: Str
) -> Map<Str, Str>? {
    let mut candidates: List<ProjectRingFnCandidate> = []
    let mut forwards: List<ProjectExternForward> = []
    for key in graph.topo_order {
        match (graph.modules.get(key), module_hirs.get(key)) {
            (some(module_), some(program)) => {
                let prefix = module_prefix(module_.path_segments)
                collect_project_ring_candidates(key, program.decls, candidates)
                collect_project_extern_forwards(key, prefix, program.decls, forwards)
            },
            _ => {}
        }
    }

    let mut bridges: Map<Str, Str> = map_new()
    let mut has_ambiguity = false
    for forward in forwards {
        let mut matching: List<ProjectRingFnCandidate> = []
        for candidate in candidates {
            if candidate.leaf == forward.abi_name &&
               candidate.signature == forward.signature &&
               module_directly_depends_on(graph, candidate.module_key, forward.module_key) {
                matching.push(candidate)
            }
        }
        if matching.len() == 1 {
            match matching.get(0) {
                some(candidate) => {
                    bridges.insert(forward.identity, candidate.identity)
                },
                none => {}
            }
        } else if matching.len() > 1 {
            report_extern_forward_ambiguity(graph, forward, matching, error_format)
            has_ambiguity = true
        }
        // A same-leaf but incompatible/unrelated definition is intentionally
        // not a candidate: preserve the raw foreign ABI symbol.
    }
    if has_ambiguity { none } else { some(bridges) }
}

fn compile_phases(entry_file: Str, error_format: Str, mut timing: PhaseTiming) -> CompilePhaseResult? {
    let graph_start = timing.start_phase()
    match build_module_graph(entry_file, error_format) {
        none => {
            timing.finish_phase(PHASE_PROJECT_MODULE_LOAD_PARSE, graph_start)
            timing.skip_phase(PHASE_TYPE_EFFECT_CHECK_LOWER)
            none
        },
        some(graph) => {
            timing.finish_phase(PHASE_PROJECT_MODULE_LOAD_PARSE, graph_start)
            let check_start = timing.start_phase()
            let mut module_asts: Map<Str, Program> = map_new()
            let mut module_hirs: Map<Str, HProgram> = map_new()
            let mut module_exports_map: Map<Str, ModuleExports> = map_new()

            // Use cached ASTs from resolver (already parsed during graph construction)
            for key in graph.topo_order {
                match graph.asts.get(key) {
                    some(ast) => { module_asts.insert(key, ast) },
                    none => {},
                }
            }

            // Check all modules in topological order
            let mut check_ok = true
            // B-145: store each module's type env so the extern-type union below
            // can filter by StructDef.is_extern, avoiding bare-name collisions.
            let mut module_envs: Map<Str, TypeEnv> = map_new()
            let mut module_order = 0
            for key in graph.topo_order {
                if check_ok {
                    match module_asts.get(key) {
                        some(ast) => {
                            let sink = new_collecting_sink()
                            let deps = match graph.dependencies.get(key) {
                                some(dk) => dk,
                                none => empty_str_list(),
                            }
                            let mut dep_exports: List<ModuleExports> = empty_module_exports_list()
                            for dk in deps {
                                match module_exports_map.get(dk) {
                                    some(e) => dep_exports.push(e),
                                    none => {},
                                }
                            }
                            let current_prefix = match graph.modules.get(key) {
                                some(mod_) => module_prefix(mod_.path_segments),
                                none => ""
                            }
                            let result = check_module(
                                ast, key, current_prefix,
                                module_order,
                                graph.namespace_plan, dep_exports, sink)
                            if sink.has_errors() {
                                let mod_file = match graph.modules.get(key) { some(m) => m.file_path, none => "" }
                                if error_format == "llm" {
                                    eprintln(format_llm(sink.diagnostics(), mod_file))
                                } else {
                                    let src = read_file(mod_file)
                                    eprintln(format_human(sink.diagnostics(), src))
                                }
                                check_ok = false
                            } else {
                                // Surface check warnings (non-error diagnostics) without failing the build
                                if sink.items.len() > 0 {
                                    let mod_file = match graph.modules.get(key) { some(m) => m.file_path, none => "" }
                                    if error_format == "llm" {
                                        eprintln(format_llm(sink.diagnostics(), mod_file))
                                    } else {
                                        let src = read_file(mod_file)
                                        eprintln(format_human(sink.diagnostics(), src))
                                    }
                                }
                                module_hirs.insert(key, result.program)
                                module_envs.insert(key, result.env)
                                match graph.modules.get(key) {
                                    some(mod_) => {
                                        let prefix = module_prefix(mod_.path_segments)
                                        let exp = extract_exports(key, prefix, ast, result.program, result.env,
                                            result.fn_mut_params, result.value_origins,
                                            result.value_binding_kinds,
                                            result.impl_facts, dep_exports)
                                        module_exports_map.insert(key, exp)
                                    },
                                    none => {},
                                }
                            }
                        },
                        none => { check_ok = false },
                    }
                }
                module_order = module_order + 1
            }
            if check_ok == false {
                timing.finish_phase(PHASE_TYPE_EFFECT_CHECK_LOWER, check_start)
                return none
            }

            // B-144 + B-145: compute per-module extern type names.
            // Step 1: collect the global union of all modules' extern type names
            // (same as B-144 — covers use-imported extern types).
            let mut global_externs: Set<Str> = set_new()
            for key in graph.topo_order {
                match module_hirs.get(key) {
                    some(hir) => {
                        for en in hir.extern_type_names { global_externs.insert(en) }
                    },
                    none => {},
                }
            }
            // Step 2: for each module, intersect global_externs with the module's
            // own type env — only include names where StructDef.is_extern is true.
            // This prevents bare-name collisions: if module B has `struct Foo`
            // (is_extern=false), "Foo" from the global set is excluded even if
            // module A declared `extern type Foo`.
            for key in graph.topo_order {
                match (module_hirs.get(key), module_envs.get(key)) {
                    (some(hir), some(env)) => {
                        let mut filtered: Set<Str> = set_new()
                        for en in global_externs {
                            // The module's own HDecl is exact declaration
                            // evidence and wins even if a later normal alias
                            // replaced the same leaf in the mutable registry.
                            if hir.extern_type_names.contains(en) {
                                filtered.insert(en)
                            } else {
                                // A named import may preserve the extern under
                                // an alias after a local normal struct replaces
                                // its raw leaf. Match the definition's exact
                                // name, rather than only looking up that leaf.
                                let mut visible_extern = false
                                for entry in env.types.structs.entries() {
                                    let (_, sdef) = entry
                                    if sdef.is_extern && sdef.name == en {
                                        visible_extern = true
                                    }
                                }
                                if visible_extern {
                                    filtered.insert(en)
                                }
                            }
                        }
                        module_hirs.insert(key, HProgram {
                            decls: hir.decls,
                            derived_impls: hir.derived_impls,
                            boxed_vars: hir.boxed_vars,
                            static_dicts: hir.static_dicts,
                            extern_type_names: filtered,
                            drop_types: hir.drop_types
                        })
                    },
                    _ => {},
                }
            }

            let bridges = build_project_extern_forward_bridges(graph, module_hirs, error_format)
            timing.finish_phase(PHASE_TYPE_EFFECT_CHECK_LOWER, check_start)
            match bridges {
                none => none,
                some(extern_forward_bridges) => some(CompilePhaseResult {
                    graph: graph,
                    module_asts: module_asts,
                    module_hirs: module_hirs,
                    module_exports_map: module_exports_map,
                    extern_forward_bridges: extern_forward_bridges
                })
            }
        },
    }
}

// ============================================================
// Bundle mode
// ============================================================

pub fn compile_project(entry_file: Str, error_format: Str, mut timing: PhaseTiming) -> CompileProjectResult {
    match compile_phases(entry_file, error_format, timing) {
        none => {
            timing.skip_phase(PHASE_RESOURCE_PLAN_VERIFY)
            CompileProjectResult { success: false }
        },
        some(_) => {
            timing.skip_phase(PHASE_RESOURCE_PLAN_VERIFY)
            CompileProjectResult { success: true }
        },
    }
}

// ============================================================
// C multi-file compilation mode.
// Modules are transformed in topological order and handed to
// generate_c_project as a single C translation unit.
// ============================================================

pub struct CProjectCompileResult {
    pub success: Bool
}

pub fn compile_project_c(
    entry_file: Str, c_path: Str, o_path: Str, emit_lines: Bool,
    error_format: Str, mut timing: PhaseTiming
) -> CProjectCompileResult {
    match compile_phases(entry_file, error_format, timing) {
        none => {
            timing.skip_phase(PHASE_RESOURCE_PLAN_VERIFY)
            CProjectCompileResult { success: false }
        },
        some(phases) => {
            let resource_start = timing.start_phase()
            let entry_key = module_key(phases.graph.entry.path_segments)

            // Build list of (module_prefix, HProgram, uses) in topo order
            let mut modules: List<(Str, HProgram, List<UseDecl>)> = []
            let mut entry_prefix = ""

            for key in phases.graph.topo_order {
                match (phases.graph.modules.get(key), phases.module_hirs.get(key), phases.module_asts.get(key)) {
                    (some(mod_), some(hir), some(ast)) => {
                        let prefix = module_prefix(mod_.path_segments)
                        let rc_hir = perceus_transform(hir)
                        modules.push((prefix, rc_hir, ast.uses))
                        if key == entry_key {
                            entry_prefix = prefix
                        }
                    },
                    (some(mod_), some(hir), none) => {
                        let prefix = module_prefix(mod_.path_segments)
                        let rc_hir = perceus_transform(hir)
                        modules.push((prefix, rc_hir, []))
                        if key == entry_key {
                            entry_prefix = prefix
                        }
                    },
                    _ => {},
                }
            }

            timing.finish_phase(PHASE_RESOURCE_PLAN_VERIFY, resource_start)
            let build_ok = generate_c_project(
                modules, entry_prefix, c_path, o_path, emit_lines,
                phases.extern_forward_bridges)
            CProjectCompileResult { success: build_ok }
        },
    }
}

// ============================================================
// B-104 D2: multi-file static RC verification
// Runs the same per-module perceus_transform as native compilation, then
// the verify_rc linear check on each module's post-RC HIR.
// ============================================================

pub struct RcProjectVerifyResult {
    pub success: Bool,
    pub fatal: Int,
    pub exempt: Int,
    pub report: Str
}

pub fn verify_project_rc(
    entry_file: Str, mutate: Str, strict: Bool, error_format: Str,
    mut timing: PhaseTiming
) -> RcProjectVerifyResult {
    match compile_phases(entry_file, error_format, timing) {
        none => {
            timing.skip_phase(PHASE_RESOURCE_PLAN_VERIFY)
            RcProjectVerifyResult { success: false, fatal: 0, exempt: 0, report: "" }
        },
        some(phases) => {
            let resource_start = timing.start_phase()
            let mut all: List<RcFinding> = []
            for key in phases.graph.topo_order {
                match phases.module_hirs.get(key) {
                    some(hir) => {
                        let rc_hir = perceus_transform_mutated(hir, mutate)
                        for f in verify_rc_program(rc_hir) { all.push(f) }
                    },
                    none => {},
                }
            }
            let fatal = rc_fatal_count(all)
            timing.finish_phase(PHASE_RESOURCE_PLAN_VERIFY, resource_start)
            RcProjectVerifyResult {
                success: true,
                fatal: fatal,
                exempt: all.len() - fatal,
                report: format_rc_findings(all, strict)
            }
        },
    }
}

fn empty_module_exports_list() -> List<ModuleExports> {
    let mut x: List<ModuleExports> = []
    x
}

fn empty_str_list() -> List<Str> {
    let mut x: List<Str> = []
    x
}
