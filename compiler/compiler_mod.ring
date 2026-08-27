use types::{nominal_display_name}
use ast::{Program, UseDecl, Span}
use hir::{HProgram, HDecl,
    module_item_identity, is_module_item_identity}
use diagnostics::{Severity, DiagnosticContext, new_collecting_sink, make_diag}
use formatter::{format_human, format_llm}
use env::{TypeEnv}
use checker::{check_module}
use core_from_hir::{
    FrozenCoreAssemblyFacts, CoreAssemblyResult,
    assemble_project_core, core_assembly_result_program,
    core_assembly_result_diagnostic_projection,
    core_assembly_result_with_program}
use core_expr::{
    CoreExecutableRedirect, make_core_executable_redirect,
    core_executable_redirect_source, core_executable_redirect_target,
    CoreCallableContract, core_callable_reference, core_callable_mode,
    core_callable_redirect_contract_same}
use core_hir::{CoreProgram, core_program_callables, core_program_type_graph,
    redirect_core_program_executables}
use ir_inventory::{ExecutableRef, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_same,
    executable_contract_mode_same,
    executable_contract_mode_concrete_body,
    executable_contract_mode_contract_only}
use ir_identity::{symbol_ref_canonical_payload}
use legacy_projection::{LegacyProjectionFacts}
use codegen_c::{generate_c_project}
use resolver::{ModuleGraph, ModuleId, module_key, module_prefix,
    build_module_graph}
use exports::{ModuleExports, extract_exports}
use legacy_projection::{assemble_legacy_projection}
use ownership_pipeline::{
    VerifiedOwnershipProgram, OwnershipPipelineOutcome,
    run_ownership_pipeline,
    ownership_pipeline_outcome_is_verified,
    ownership_pipeline_outcome_verified,
    ownership_pipeline_failure_diagnostics,
    verified_ownership_program_flow}
use rc_hir_bridge::{VerifiedProjectHirShell,
    make_verified_project_hir_shell, materialize_verified_project_hir,
    materialized_project_hir_module_key,
    materialized_project_hir_program}
use codes::{E0708}
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
    prelude_physical_owner_module_key: Str,
    module_asts: Map<Str, Program>,
    module_hirs: Map<Str, HProgram>,
    module_core_facts: Map<Str, FrozenCoreAssemblyFacts>,
    module_legacy_facts: Map<Str, LegacyProjectionFacts>,
    module_exports_map: Map<Str, ModuleExports>,
    extern_forward_candidates: List<ProjectExternForwardCandidateSet>
}

struct ProjectOwnershipRun {
    assembly: CoreAssemblyResult,
    ownership: OwnershipPipelineOutcome,
    redirects: List<CoreExecutableRedirect>
}

fn run_project_ownership(
    phases: CompilePhaseResult, error_format: Str
) -> ProjectOwnershipRun? {
    let mut core_facts: List<FrozenCoreAssemblyFacts> = []
    for key in phases.graph.topo_order {
        core_facts.push(phases.module_core_facts.get(key).unwrap_or_else(fn() {
            panic("project ownership: Core facts are absent")
        }))
    }
    let assembled = assemble_project_core(core_facts)
    let program = core_assembly_result_program(assembled)
    let redirects = match resolve_project_extern_redirects(
            phases, program, error_format) {
        some(value) => value,
        none => return none
    }
    let redirected = redirect_core_program_executables(program, redirects)
    let assembly = core_assembly_result_with_program(assembled, redirected)
    some(ProjectOwnershipRun {
        assembly: assembly,
        ownership: run_ownership_pipeline(
            core_assembly_result_program(assembly)),
        redirects: redirects
    })
}

fn report_project_ownership_failure(
    phases: CompilePhaseResult, assembly: CoreAssemblyResult,
    outcome: OwnershipPipelineOutcome, error_format: Str
) {
    let projection = core_assembly_result_diagnostic_projection(assembly)
    let routed = ownership_pipeline_failure_diagnostics(
        outcome, projection)
    for projected in routed {
        let (finding_module_key, diagnostic) = projected
        let module = phases.graph.modules.get(
            finding_module_key).unwrap_or_else(fn() {
                panic("project ownership diagnostic: projected module is absent")
            })
        if diagnostic.span.file != module.file_path {
            panic("project ownership diagnostic: projected span crosses module file")
        }
    }
    let mut emitted = false
    for key in phases.graph.topo_order {
        let mut sink = new_collecting_sink()
        for routed_diagnostic in routed {
            let (finding_module_key, diagnostic) = routed_diagnostic
            if finding_module_key == key {
                sink.report(diagnostic)
            }
        }
        if sink.has_errors() {
            emitted = true
            let module = phases.graph.modules.get(key).unwrap_or_else(fn() {
                panic("project ownership diagnostic: module is absent")
            })
            if error_format == "llm" {
                eprintln(format_llm(sink.diagnostics(), module.file_path))
            } else {
                eprintln(format_human(
                    sink.diagnostics(), read_file(module.file_path)))
            }
        }
    }
    if !emitted {
        panic("project ownership diagnostic: failed plan emitted no error")
    }
}

fn materialize_verified_project_ownership(
    phases: CompilePhaseResult, assembly: CoreAssemblyResult,
    verified: VerifiedOwnershipProgram
) -> Map<Str, HProgram> {
    let mut legacy_facts: List<LegacyProjectionFacts> = []
    let mut shells: List<VerifiedProjectHirShell> = []
    for key in phases.graph.topo_order {
        legacy_facts.push(
            phases.module_legacy_facts.get(key).unwrap_or_else(fn() {
                panic("project ownership: legacy facts are absent")
            }))
        shells.push(make_verified_project_hir_shell(
            key, phases.module_hirs.get(key).unwrap_or_else(fn() {
                panic("project ownership: HIR shell is absent")
            })))
    }
    let projection = assemble_legacy_projection(
        legacy_facts, assembly,
        verified_ownership_program_flow(verified))
    let materialized = materialize_verified_project_hir(
        shells, phases.prelude_physical_owner_module_key, verified, projection)
    let mut result: Map<Str, HProgram> = map_new()
    for value in materialized {
        let key = materialized_project_hir_module_key(value)
        if result.contains_key(key) {
            panic("project ownership: materialized module repeats")
        }
        result.insert(key, materialized_project_hir_program(value))
    }
    if result.len() != phases.graph.topo_order.len() {
        panic("project ownership: materialized module census differs")
    }
    result
}

// Project checking produces one already-dict-lowered HProgram per module.
// Keep builtin derived bodies in the first deterministic physical carrier so
// project codegen observes the same builtin-before-user order as single-file
// codegen without per-module synthesis or backend deduplication.
struct ProjectRingFnCandidate {
    module_key: Str,
    executable: ExecutableRef,
    leaf: Str
}

struct ProjectExternForward {
    module_key: Str,
    executable: ExecutableRef,
    abi_name: Str,
    span: Span
}

struct ProjectExternForwardCandidateSet {
    forward: ProjectExternForward,
    candidates: List<ProjectRingFnCandidate>
}

fn project_executable_identity(value: ExecutableRef) -> Str {
    if !executable_ref_is_named(value) {
        panic("project extern forward: executable is not named")
    }
    symbol_ref_canonical_payload(executable_ref_named_symbol(value))
}

fn project_identity_leaf(identity: Str) -> Str {
    let inline_parts = identity.split("::")
    let inline_leaf = inline_parts.get(inline_parts.len() - 1).unwrap_or(identity)
    let file_parts = inline_leaf.split("$$_")
    file_parts.get(file_parts.len() - 1).unwrap_or(inline_leaf)
}

fn collect_project_ring_candidates(
    module_key_: Str, decls: List<HDecl>, mut out: List<ProjectRingFnCandidate>
) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, executable_ref, is_pub, .. } => {
                // Raw prelude functions are repeated in every HProgram. Only a
                // canonical project definition may satisfy a project forward.
                if is_pub && is_module_item_identity(name) {
                    out.push(ProjectRingFnCandidate {
                        module_key: module_key_, executable: executable_ref,
                        leaf: project_identity_leaf(name)
                    })
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
            HDecl::ExternFn { name, abi_name, executable_ref, span, .. } => {
                // Prelude externs use compiler-intrinsic identities and inline
                // externs have an additional `::` component. Only this file
                // module's exact top-level declaration may cycle-break.
                if name == module_item_identity(module_prefix_, abi_name) {
                    out.push(ProjectExternForward {
                        module_key: module_key_, executable: executable_ref,
                        abi_name: abi_name, span: span
                    })
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
    for candidate in candidates {
        names.push(nominal_display_name(
            project_executable_identity(candidate.executable)))
    }
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

// HIR discovery only identifies possible providers by the existing ABI leaf
// and deliberate reverse-dependency shape.  It never compares a rendered
// type.  The one global CoreProgram below owns exact contract selection.
fn build_project_extern_forward_candidates(
    graph: ModuleGraph, module_hirs: Map<Str, HProgram>
) -> List<ProjectExternForwardCandidateSet> {
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

    let mut result: List<ProjectExternForwardCandidateSet> = []
    for forward in forwards {
        let mut matching: List<ProjectRingFnCandidate> = []
        for candidate in candidates {
            if candidate.leaf == forward.abi_name &&
               module_directly_depends_on(graph, candidate.module_key, forward.module_key) {
                matching.push(candidate)
            }
        }
        result.push(ProjectExternForwardCandidateSet {
            forward: forward, candidates: matching
        })
    }
    result
}

fn project_core_callable(
    callables: List<CoreCallableContract>, reference: ExecutableRef
) -> CoreCallableContract {
    let mut found: CoreCallableContract? = none
    for callable in callables {
        if executable_ref_same(core_callable_reference(callable), reference) {
            if found.is_some() {
                panic("project extern forward: callable contract repeats")
            }
            found = some(callable)
        }
    }
    match found {
        some(value) => value,
        none => panic("project extern forward: exact callable is absent")
    }
}

fn resolve_project_extern_redirects(
    phases: CompilePhaseResult, program: CoreProgram, error_format: Str
) -> List<CoreExecutableRedirect>? {
    let graph = core_program_type_graph(program)
    let callables = core_program_callables(program)
    let mut redirects: List<CoreExecutableRedirect> = []
    let mut has_ambiguity = false
    for group in phases.extern_forward_candidates {
        let source = project_core_callable(
            callables, group.forward.executable)
        if !executable_contract_mode_same(
                core_callable_mode(source),
                executable_contract_mode_contract_only()) {
            panic("project extern forward: source is not contract-only")
        }
        let mut matching: List<ProjectRingFnCandidate> = []
        for candidate in group.candidates {
            let target = project_core_callable(
                callables, candidate.executable)
            if executable_contract_mode_same(
                    core_callable_mode(target),
                    executable_contract_mode_concrete_body()) &&
               core_callable_redirect_contract_same(source, target, graph) {
                matching.push(candidate)
            }
        }
        if matching.len() == 1 {
            redirects.push(make_core_executable_redirect(
                group.forward.executable,
                matching.get(0).unwrap().executable))
        } else if matching.len() > 1 {
            report_extern_forward_ambiguity(
                phases.graph, group.forward, matching, error_format)
            has_ambiguity = true
        }
        // Zero exact Core matches is an ordinary raw extern.  A same-leaf
        // nominal from another module cannot manufacture a redirect.
    }
    if has_ambiguity { none } else { some(redirects) }
}

fn codegen_extern_forward_bridges(
    values: List<CoreExecutableRedirect>
) -> Map<Str, Str> {
    let mut result: Map<Str, Str> = map_new()
    for value in values {
        let source = project_executable_identity(
            core_executable_redirect_source(value))
        let target = project_executable_identity(
            core_executable_redirect_target(value))
        if source == target || result.contains_key(source) {
            panic("project extern forward: typed redirect is invalid/duplicated")
        }
        result.insert(source, target)
    }
    result
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
            let mut module_core_facts: Map<Str, FrozenCoreAssemblyFacts> = map_new()
            let mut module_legacy_facts: Map<Str, LegacyProjectionFacts> = map_new()
            let mut module_exports_map: Map<Str, ModuleExports> = map_new()
            let prelude_physical_owner_module_key =
                graph.topo_order.get(0).unwrap_or_else(fn() {
                    panic("project checker: module graph has no physical prelude owner")
                })

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
                                prelude_physical_owner_module_key,
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
                                if result.prelude_physical_owner_module_key !=
                                        prelude_physical_owner_module_key {
                                    panic("project checker: module prelude owner drifted")
                                }
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
                                module_core_facts.insert(key, match result.core_facts {
                                    some(value) => value,
                                    none => panic(
                                        "project ownership: successful module lacks Core facts")
                                })
                                module_legacy_facts.insert(key, match result.legacy_facts {
                                    some(value) => value,
                                    none => panic(
                                        "project ownership: successful module lacks legacy facts")
                                })
                                module_envs.insert(key, result.env)
                                match graph.modules.get(key) {
                                    some(mod_) => {
                                        let prefix = module_prefix(mod_.path_segments)
                                        let exp = extract_exports(key, prefix, ast, result.program, result.env,
                                            result.fn_mut_params, result.value_symbols,
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

            let candidates = build_project_extern_forward_candidates(
                graph, module_hirs)
            timing.finish_phase(PHASE_TYPE_EFFECT_CHECK_LOWER, check_start)
            some(CompilePhaseResult {
                graph: graph,
                prelude_physical_owner_module_key:
                    prelude_physical_owner_module_key,
                module_asts: module_asts,
                module_hirs: module_hirs,
                module_core_facts: module_core_facts,
                module_legacy_facts: module_legacy_facts,
                module_exports_map: module_exports_map,
                extern_forward_candidates: candidates
            })
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
        some(phases) => {
            let resource_start = timing.start_phase()
            let run_result = run_project_ownership(phases, error_format)
            if run_result.is_none() {
                timing.finish_phase(
                    PHASE_RESOURCE_PLAN_VERIFY, resource_start)
                return CompileProjectResult { success: false }
            }
            let run = run_result.unwrap()
            let assembly = run.assembly
            let ownership = run.ownership
            if !ownership_pipeline_outcome_is_verified(ownership) {
                report_project_ownership_failure(
                    phases, assembly, ownership, error_format)
                timing.finish_phase(PHASE_RESOURCE_PLAN_VERIFY, resource_start)
                return CompileProjectResult { success: false }
            }
            let _ = materialize_verified_project_ownership(
                phases, assembly,
                ownership_pipeline_outcome_verified(ownership))
            timing.finish_phase(PHASE_RESOURCE_PLAN_VERIFY, resource_start)
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
            let run_result = run_project_ownership(phases, error_format)
            if run_result.is_none() {
                timing.finish_phase(
                    PHASE_RESOURCE_PLAN_VERIFY, resource_start)
                return CProjectCompileResult { success: false }
            }
            let run = run_result.unwrap()
            let assembly = run.assembly
            let ownership = run.ownership
            if !ownership_pipeline_outcome_is_verified(ownership) {
                report_project_ownership_failure(
                    phases, assembly, ownership, error_format)
                timing.finish_phase(PHASE_RESOURCE_PLAN_VERIFY, resource_start)
                return CProjectCompileResult { success: false }
            }
            let materialized = materialize_verified_project_ownership(
                phases, assembly,
                ownership_pipeline_outcome_verified(ownership))

            // Build list of (module_prefix, HProgram, uses) in topo order
            let mut modules: List<(Str, HProgram, List<UseDecl>)> = []
            let mut entry_prefix = ""

            for key in phases.graph.topo_order {
                match (phases.graph.modules.get(key), materialized.get(key), phases.module_asts.get(key)) {
                    (some(mod_), some(hir), some(ast)) => {
                        let prefix = module_prefix(mod_.path_segments)
                        modules.push((prefix, hir, ast.uses))
                        if key == entry_key {
                            entry_prefix = prefix
                        }
                    },
                    (some(mod_), some(hir), none) => {
                        let prefix = module_prefix(mod_.path_segments)
                        modules.push((prefix, hir, []))
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
                codegen_extern_forward_bridges(run.redirects))
            CProjectCompileResult { success: build_ok }
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
