use types::{Type, Effect, EffectRow, UNIT, BUILTIN_OPTION,
    nominal_display_name}
use ast::{Program, Decl, UseDecl, UseImport, Span, TypeParam, span_zero}
use hir::{HDecl, HProgram, ModuleImplFact, ValueBindingKind,
    compare_by_first,
    map_index_helper_source_name, map_index_helper_identity,
    prelude_extern_identity}
use diagnostics::{Severity, DiagnosticContext, CollectingSink, new_collecting_sink, make_diag}
use env::{TypeEnv, TypeScheme, StructDef, EnumDef, EffectDef, TraitDef,
    add_impl, find_impl,
    find_impl_by_provider, impl_entry_exact_key_same,
    optional_symbol_ref_same, install_method_core,
    localize_imported_type_scheme,
    localize_imported_struct_def, localize_imported_enum_def,
    localize_imported_effect_def, localize_imported_trait_def,
    localize_imported_impl_entry,
    publish_effect_header_schema,
    register_callable_effect_header,
    register_compiler_owned_extern_source,
    close_compiler_owned_extern_sources,
    compiler_owned_extern_symbol,
    compiler_owned_extern_should_publish_hdecl,
    commit_struct_resource_storage_parameter_ordinals}
use builtins::{register_builtins, register_hof_intrinsics,
    finalize_std_hof_fallbacks, builtin_range_hdecl,
    checker_only_builtin_values, checker_builtin_value_name,
    checker_builtin_value_symbol,
    builtin_method_contract_facts, builtin_method_contract_intrinsic,
    builtin_method_contract_scheme,
    builtin_value_contract_facts, builtin_value_contract_executable,
    builtin_value_contract_scheme}
use derive::{validate_derived_impls}
use infer_decl::{check as infer_check, check_module_identity,
    check_prelude_decl, check_registered_prelude_file}
use dict_lower::{lower_dicts}
use andor_lower::{lower_andor}
use infer_ctx::{InferCtx, new_infer_ctx as new_base_infer_ctx,
    type_error, record_value_origin,
    record_value_binding_kind, record_value_symbol_ref,
    install_project_namespace_plan,
    install_struct_identity_ledger, enter_struct_identity_root_frame,
    exit_struct_identity_frame, close_struct_identity_ledger}
use infer_register::{register_decl_public}
use exports::{ModuleExports, TypeDef, physical_nominal_inputs_for_core}
use resolver::{ResolvedNamespacePlan, ModuleFramePlan, AstSite, ImportIssue,
    ImportIssueKind, NamespaceKind, first_duplicate_direct_declaration,
    duplicate_direct_declaration_diagnostic,
    reserved_type_declaration_diagnostic,
    reserved_type_name_diagnostic,
    single_namespace_file_key, resolve_single_namespace_plan,
    prelude_namespace_file_key, resolve_prelude_namespace_plan}
use codes::{E0504, E0702, E0703, E0704, E0705, E0707}
use parser::{parse}
use ir_identity::{SymbolRef, RegisteredNominalRef,
    impl_owner_ref_same, impl_method_ref_owner,
    impl_owner_ref_trait, impl_owner_ref_provider, impl_method_ref_same,
    registered_nominal_ref_symbol, registered_nominal_ref_same,
    registered_trait_ref_same, symbol_ref_same,
    handled_effect_ref_same,
    trait_method_ref_member,
    intrinsic_ref_symbol,
    symbol_ref_origin_module_key, symbol_ref_namespace_kind,
    symbol_ref_canonical_payload, symbol_ref_declaration_site_path,
    namespace_kind_same, make_symbol_ref, namespace_value,
    namespace_nominal,
    variant_ref_member}
use ir_inventory::{effect_operation_ref_callable, make_named_executable_ref}
use union_find::{UnionFind}
use core_from_hir::{FrozenCoreAssemblyFacts}
use legacy_projection::{LegacyProjectionFacts}
use core_legacy_freeze::{freeze_core_and_legacy_facts,
    frozen_core_and_legacy_core, frozen_core_and_legacy_legacy}
use scc::{build_call_graph, collect_registered_fn_names}

pub struct CheckResult {
    pub program: HProgram,
    pub env: TypeEnv,
    pub fn_mut_params: Map<Str, List<Bool>>,
    // Exact lexical DefId -> registration kind.  Export extraction consumes
    // this map so same-file inline aliases retain provenance across arbitrary
    // pub-use hops without falling back to leaf-name guesses.
    pub value_binding_kinds: Map<Int, ValueBindingKind>,
    pub value_symbols: Map<Int, SymbolRef>,
    pub core_facts: FrozenCoreAssemblyFacts?,
    pub legacy_facts: LegacyProjectionFacts?,
    pub prelude_physical_owner_module_key: Str,
    // User-declared impl blocks with the canonical target identity resolved
    // during checking (while namespace frames were live). Collected from the
    // module's own HIR before prelude decls are prepended, so exports never
    // have to re-resolve an impl target against the rolled-back environment.
    pub impl_facts: List<ModuleImplFact>
}

fn failed_check_result(
    ctx: InferCtx, prelude_physical_owner_module_key: Str
) -> CheckResult {
    CheckResult {
        program: HProgram {
            decls: [],
            derived_impls: [],
            boxed_vars: set_new(),
            static_dicts: [],
            extern_type_names: set_new(),
            drop_types: set_new()
        },
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params,
        value_binding_kinds: map_clone(ctx.value_binding_kinds),
        value_symbols: map_clone(ctx.value_symbols),
        core_facts: none,
        legacy_facts: none,
        prelude_physical_owner_module_key:
            prelude_physical_owner_module_key,
        impl_facts: []
    }
}

const STD_FILES: List<Str> =
    ["str.ring", "io.ring", "iterator.ring", "list.ring", "map.ring", "set.ring", "num.ring", "result.ring", "fs.ring", "path.ring", "process.ring"]

fn canonicalize_prelude_decl(decl: Decl) -> Decl {
    match decl {
        Decl::Fn { name, type_params, params, return_type, declared_effects,
                   body, is_pub, is_abstract, span } => {
            if name == map_index_helper_source_name() {
                // Compiler-synthesised Map indexing must target an identity no
                // Ring source identifier can spell.  Keep the raw API as an
                // environment alias below; the emitted definition is private
                // so project-link candidate collection ignores it.
                Decl::Fn {
                    name: map_index_helper_identity(),
                    type_params: type_params, params: params,
                    return_type: return_type, declared_effects: declared_effects,
                    body: body, is_pub: false, is_abstract: is_abstract, span: span
                }
            } else {
                Decl::Fn {
                    name: name, type_params: type_params, params: params,
                    return_type: return_type, declared_effects: declared_effects,
                    body: body, is_pub: is_pub, is_abstract: is_abstract, span: span
                }
            }
        },
        _ => decl
    }
}

fn find_std_dir() -> Str? {
    let candidates = [
        path_resolve(path_join(path_dirname(path_resolve(".")), "std")),
        path_resolve("std")
    ]
    for dir in candidates {
        if file_exists(dir) { return some(dir) }
    }
    none
}

fn canonical_prelude_extern_symbol(
    env: TypeEnv, source: SymbolRef, name: Str
) -> SymbolRef {
    match compiler_owned_extern_symbol(env, source) {
        some(symbol) => symbol,
        none => make_symbol_ref(
            "$prelude$::extern", namespace_value(),
            prelude_extern_identity(name), "prelude-extern:${name}")
    }
}

struct PreludeDeclSite {
    decl: Decl,
    file_key: Str,
    decl_index: Int,
    source_symbol: SymbolRef?
}

fn prelude_callable_decl(decl: Decl) -> Decl? {
    match decl {
        Decl::Fn { .. } => some(decl),
        Decl::Impl {
            target_type, type_params, trait_name, methods, span
        } => {
            // Compiler-owned impl externs are runtime leaves.  Keep the
            // ordinary methods on the registered source owner, but never add
            // those extern members to the A1 body program.
            let mut fn_methods: List<Decl> = []
            for method in methods {
                match method {
                    Decl::Fn { .. } => fn_methods.push(method),
                    _ => {}
                }
            }
            if fn_methods.len() == 0 {
                none
            } else {
                some(Decl::Impl {
                    target_type: target_type,
                    type_params: type_params,
                    trait_name: trait_name,
                    methods: fn_methods,
                    span: span
                })
            }
        },
        _ => none
    }
}

fn prelude_callable_program(
    sites: List<PreludeDeclSite>, file_key: Str
) -> (Program, List<Int>) {
    let mut decls: List<Decl> = []
    let mut decl_site_indices: List<Int> = []
    for site in sites {
        if site.file_key == file_key {
            match prelude_callable_decl(site.decl) {
                some(decl) => {
                    decls.push(decl)
                    decl_site_indices.push(site.decl_index)
                },
                none => {}
            }
        }
    }
    (Program { uses: [], decls: decls, span: span_zero() },
        decl_site_indices)
}

fn preflight_prelude_file_dag(
    program: Program, all_registered_fns: Set<Str>,
    future_registered_fns: Set<Str>, file_key: Str
) {
    // This graph is validation-only.  STD_FILES remains the sole cross-file
    // scheduler; the ordinary per-file graph below remains the sole SCC
    // authority.  Any cross-file cycle necessarily contains an edge against
    // the fixed total order, so rejecting future targets also rejects cycles.
    let graph = build_call_graph(program.decls, all_registered_fns, some(""))
    let mut entries = graph.entries()
    entries.sort_by(compare_by_first)
    for entry in entries {
        let (caller, callees) = entry
        for callee in callees {
            if future_registered_fns.contains(callee) {
                panic("prelude file DAG: reverse edge '${caller}' -> '${callee}' in '${file_key}'")
            }
        }
    }
}

fn prelude_struct_storage_parameter_ordinals(
    site: PreludeDeclSite, decl: HDecl
) -> (RegisteredNominalRef, List<Int>)? {
    let relation = match decl {
        HDecl::Struct { owner_ref, type_params, .. } =>
            some((owner_ref, type_params.len())),
        _ => none
    }
    let relation = match relation {
        some(value) => value,
        none => return none
    }
    if site.decl_index != 0 { return none }
    let expected = if site.file_key == "$prelude$::list" {
        some(("$prelude$$list$$_List", 1, [0]))
    } else if site.file_key == "$prelude$::map" {
        some(("$prelude$$map$$_Map", 2, [0, 1]))
    } else if site.file_key == "$prelude$::set" {
        some(("$prelude$$set$$_Set", 1, [0]))
    } else {
        none
    }
    match expected {
        some((payload, arity, ordinals)) => {
            let symbol = registered_nominal_ref_symbol(relation.0)
            if relation.1 != arity ||
               symbol_ref_origin_module_key(symbol) != site.file_key ||
               !namespace_kind_same(
                    symbol_ref_namespace_kind(symbol), namespace_nominal()) ||
               symbol_ref_canonical_payload(symbol) != payload ||
               symbol_ref_declaration_site_path(symbol) != "frame:0|item:0" {
                panic("prelude storage contract: exact source identity differs")
            }
            some((relation.0, ordinals))
        },
        none => none
    }
}

fn load_prelude(mut ctx: InferCtx) -> List<HDecl> {
    let mut prelude_hdecls: List<HDecl> = []
    match find_std_dir() {
        some(std_dir) => {
            // Phase 1: collect and register all prelude declarations
            let mut all_prelude_decls: List<PreludeDeclSite> = []
            for file in (STD_FILES) {
                let file_path = path_join(std_dir, file)
                if file_exists(file_path) {
                    let source = read_file(file_path)
                    let prelude_sink = new_collecting_sink()
                    let ast = parse(source, file_path, prelude_sink)
                    let mut canonical_decls: List<Decl> = []
                    for decl in ast.decls {
                        canonical_decls.push(canonicalize_prelude_decl(decl))
                    }
                    let canonical_program = Program {
                        uses: ast.uses,
                        decls: canonical_decls,
                        span: ast.span
                    }
                    let prelude_file_key = prelude_namespace_file_key(file_path)
                    let prelude_plan = resolve_prelude_namespace_plan(
                        file_path, canonical_program)
                    let root_frame = match prelude_plan.frames.find(fn(frame) {
                        frame.file_key == prelude_file_key &&
                            frame.parent_frame_index < 0
                    }) {
                        some(frame) => frame.frame_index,
                        none => panic("prelude value identity: root frame is absent")
                    }
                    install_struct_identity_ledger(
                        ctx, prelude_file_key, prelude_plan)
                    enter_struct_identity_root_frame(ctx)
                    for decl_index in 0..canonical_decls.len() {
                        let canonical_decl = canonical_decls.get(
                            decl_index).unwrap()
                        let mut source_symbol: SymbolRef? = none
                        let local_name = match canonical_decl {
                            Decl::Fn { name, .. } => some(name),
                            Decl::ExternFn { name, .. } => some(name),
                            Decl::Const { name, .. } => some(name),
                            _ => none
                        }
                        match local_name {
                            some(name) => {
                                let mut matches = 0
                                for binding in prelude_plan.bindings {
                                    if binding.file_key == prelude_file_key &&
                                       binding.frame_index == root_frame &&
                                       binding.exposed_name == name {
                                        match binding.namespace {
                                            NamespaceKind::Value => {
                                                matches = matches + 1
                                            },
                                            _ => {}
                                        }
                                    }
                                }
                                if matches != 1 {
                                    panic("prelude value identity: direct binding is not unique")
                                }
                                for binding in prelude_plan.bindings {
                                    if binding.file_key == prelude_file_key &&
                                       binding.frame_index == root_frame &&
                                       binding.exposed_name == name {
                                        match binding.namespace {
                                            NamespaceKind::Value => {
                                                register_decl_public(
                                                    ctx, canonical_decl, decl_index,
                                                    some(symbol_ref_canonical_payload(
                                                        binding.symbol)))
                                                record_value_symbol_ref(
                                                    ctx, name, binding.symbol)
                                                source_symbol = some(binding.symbol)
                                                match canonical_decl {
                                                    Decl::ExternFn {
                                                        name, type_params, ..
                                                    } => {
                                                        let source_scheme = ctx.env.lookup(
                                                            name).unwrap_or_else(fn() {
                                                            panic("compiler extern manifest: registered source scheme is absent")
                                                        })
                                                        let _ = register_compiler_owned_extern_source(
                                                            ctx.env, binding.symbol,
                                                            source_scheme,
                                                            type_params.len())
                                                    },
                                                    _ => {}
                                                }
                                            },
                                            _ => {}
                                        }
                                    }
                                }
                            },
                            none => register_decl_public(
                                ctx, canonical_decl, decl_index, none)
                        }
                        all_prelude_decls.push(PreludeDeclSite {
                            decl: canonical_decl,
                            file_key: prelude_file_key,
                            decl_index: decl_index,
                            source_symbol: source_symbol
                        })
                    }
                    exit_struct_identity_frame(ctx)
                    close_struct_identity_ledger(ctx)
                }
            }
            close_compiler_owned_extern_sources(ctx.env)
            // Install the source-level API spelling as an alias of the exact
            // canonical scheme/DefId. record_value_origin makes ordinary
            // explicit calls use the same backend-safe canonical identity too.
            let map_get_name = map_index_helper_source_name()
            let map_get_identity = map_index_helper_identity()
            match ctx.env.lookup(map_get_identity) {
                some(scheme) => {
                    ctx.env.bind(map_get_name, scheme)
                    record_value_origin(ctx, map_get_name, map_get_identity)
                },
                none => {}
            }
            // Phase 1 has finished, so duplicate std declarations now resolve
            // to their final exact DefIds. Give every top-level prelude extern
            // an unspellable semantic identity; later user fn/const bindings
            // receive distinct DefIds and cannot collide in backend registries.
            for site in all_prelude_decls {
                match site.decl {
                    Decl::ExternFn { name, .. } => {
                        record_value_origin(ctx, name,
                            prelude_extern_identity(name))
                    },
                    _ => {}
                }
            }
            // Phase 2 follows the fixed file DAG.  The global name set is used
            // only to reject edges against that order; each file still builds
            // and closes its own ordinary A1 call graph.
            let mut all_callable_decls: List<Decl> = []
            for site in all_prelude_decls {
                match prelude_callable_decl(site.decl) {
                    some(decl) => all_callable_decls.push(decl),
                    none => {}
                }
            }
            let all_registered_fns = collect_registered_fn_names(
                all_callable_decls)
            let mut future_registered_fns: Set<Str> = set_new()
            for name in all_registered_fns {
                future_registered_fns.insert(name)
            }

            // Validate the entire fixed DAG before Phase 2 publishes any HIR.
            for file in (STD_FILES) {
                let file_path = path_join(std_dir, file)
                if file_exists(file_path) {
                    let file_key = prelude_namespace_file_key(file_path)
                    let (callable_program, _) = prelude_callable_program(
                        all_prelude_decls, file_key)
                    let file_registered_fns = collect_registered_fn_names(
                        callable_program.decls)
                    for name in file_registered_fns {
                        future_registered_fns.remove(name)
                    }
                    if callable_program.decls.len() > 0 {
                        preflight_prelude_file_dag(
                            callable_program, all_registered_fns,
                            future_registered_fns, file_key)
                    }
                }
            }

            let mut published_prelude_externs: List<SymbolRef> = []
            for file in (STD_FILES) {
                let file_path = path_join(std_dir, file)
                if file_exists(file_path) {
                    let file_key = prelude_namespace_file_key(file_path)

                    // Non-callable declarations retain their existing exact
                    // single-decl path.  In particular, every duplicate extern
                    // is finalized before its publish filter is applied and is
                    // never inserted into the per-file A1 Program.
                    for site in all_prelude_decls {
                        if site.file_key == file_key {
                            let decl = site.decl
                            match prelude_callable_decl(decl) {
                                some(_) => {},
                                none => match decl {
                                    Decl::Struct { .. } => {
                                        let result = some(check_prelude_decl(
                                            ctx, decl, site.file_key,
                                            site.decl_index, none)) catch {
                                            _ => none
                                        }
                                        match result {
                                            some(hd) => {
                                                match prelude_struct_storage_parameter_ordinals(
                                                        site, hd) {
                                                    some((owner, ordinals)) =>
                                                        commit_struct_resource_storage_parameter_ordinals(
                                                            ctx.env, owner, ordinals),
                                                    none => {}
                                                }
                                                prelude_hdecls.push(hd)
                                            },
                                            none => {}
                                        }
                                    },
                                    Decl::ExternFn { name, .. } => {
                                        let source = match site.source_symbol {
                                            some(symbol) => symbol,
                                            none => panic(
                                                "compiler extern manifest: Phase 2 source symbol is absent")
                                        }
                                        let final_symbol =
                                            canonical_prelude_extern_symbol(
                                                ctx.env, source, name)
                                        let mut already_published = false
                                        for existing in published_prelude_externs {
                                            if symbol_ref_same(
                                                    existing, final_symbol) {
                                                already_published = true
                                            }
                                        }
                                        let publish = match
                                                compiler_owned_extern_should_publish_hdecl(
                                                    ctx.env, source) {
                                            some(value) => {
                                                if value && already_published {
                                                    panic("compiler extern manifest: publication owner repeats")
                                                }
                                                value
                                            },
                                            none => !already_published
                                        }
                                        let result = some(check_prelude_decl(
                                            ctx, decl, site.file_key,
                                            site.decl_index,
                                            some(final_symbol))) catch {
                                            _ => none
                                        }
                                        match result {
                                            some(HDecl::ExternFn {
                                                name, abi_name, def_id,
                                                executable_ref, type_params,
                                                params, return_type, effects,
                                                resource_contract, trait_bounds,
                                                is_pub, span
                                            }) => {
                                                if publish {
                                                    // The source spelling is
                                                    // diagnostic/ABI metadata
                                                    // only. ExecutableRef is
                                                    // the downstream identity.
                                                    prelude_hdecls.push(
                                                        HDecl::ExternFn {
                                                        name: name,
                                                        abi_name: abi_name,
                                                        def_id: def_id,
                                                        executable_ref:
                                                            executable_ref,
                                                        type_params: type_params,
                                                        params: params,
                                                        return_type: return_type,
                                                        effects: effects,
                                                        resource_contract:
                                                            resource_contract,
                                                        trait_bounds: trait_bounds,
                                                        is_pub: is_pub,
                                                        span: span
                                                    })
                                                    published_prelude_externs.push(
                                                        final_symbol)
                                                }
                                            },
                                            some(_) => {},
                                            none => {}
                                        }
                                    },
                                    Decl::Impl { .. } => {},
                                    _ => {
                                        let result = some(check_prelude_decl(
                                            ctx, decl, site.file_key,
                                            site.decl_index, none)) catch {
                                            _ => none
                                        }
                                        match result {
                                            some(hd) => prelude_hdecls.push(hd),
                                            none => {}
                                        }
                                    }
                                }
                            }
                        }
                    }

                    let (callable_program, callable_sites) =
                        prelude_callable_program(all_prelude_decls, file_key)
                    if callable_program.decls.len() > 0 {
                        let checked = check_registered_prelude_file(
                            ctx, callable_program, file_key, callable_sites)
                        for hdecl in checked {
                            prelude_hdecls.push(hdecl)
                        }
                    }
                }
            }
        },
        none => {
            finalize_std_hof_fallbacks(ctx.env, ctx.sink)
        },
    }
    prelude_hdecls.push(builtin_range_hdecl(ctx.env))
    prelude_hdecls
}

fn new_infer_ctx(
    sink: CollectingSink, module_key: Str, module_order: Int
) -> InferCtx {
    let mut ctx = new_base_infer_ctx(
        sink, module_key, module_order)
    register_builtins(ctx.env, sink)
    register_hof_intrinsics(ctx.env, sink)
    for fact in builtin_method_contract_facts(ctx.env) {
        let executable = make_named_executable_ref(intrinsic_ref_symbol(
            builtin_method_contract_intrinsic(fact)))
        let scheme = builtin_method_contract_scheme(fact)
        publish_effect_header_schema(ctx.env, scheme.effect_schema)
        if module_order == 0 {
            match scheme.ty {
                Type::FnType { effects, .. } =>
                    register_callable_effect_header(
                        ctx.env, executable, effects),
                _ => panic(
                    "effect header registry: builtin method is not callable")
            }
        }
    }
    for fact in builtin_value_contract_facts() {
        let executable = builtin_value_contract_executable(fact)
        let scheme = builtin_value_contract_scheme(fact)
        publish_effect_header_schema(ctx.env, scheme.effect_schema)
        if module_order == 0 {
            match scheme.ty {
                Type::FnType { effects, .. } =>
                    register_callable_effect_header(
                        ctx.env, executable, effects),
                _ => panic(
                    "effect header registry: builtin value is not callable")
            }
        }
    }
    // Option is registered before resolver-backed source declarations exist.
    // Bind its two lexical constructor DefIds to the exact typed variant
    // members here; downstream inference never reconstructs identity from
    // `Option_some` / `Option_none` codegen spellings.
    let option_def = match ctx.env.types.enums.get(BUILTIN_OPTION) {
        some(value) => value,
        none => panic("builtin Option identity: enum definition is missing")
    }
    let some_ref = match option_def.variant_refs.get(0) {
        some(value) => value,
        none => panic("builtin Option identity: some VariantRef is missing")
    }
    let none_ref = match option_def.variant_refs.get(1) {
        some(value) => value,
        none => panic("builtin Option identity: none VariantRef is missing")
    }
    record_value_symbol_ref(ctx, "some", variant_ref_member(some_ref))
    record_value_symbol_ref(ctx, "none", variant_ref_member(none_ref))
    // These bindings are created only by register_builtins above. Record their
    // freshly allocated DefIds now; later same-spelled locals cannot inherit
    // this provenance. Option constructors use the exact variant path above.
    for builtin in checker_only_builtin_values() {
        let name = checker_builtin_value_name(builtin)
        record_value_binding_kind(ctx, name, ValueBindingKind::ExternCallable)
        record_value_symbol_ref(
            ctx, name, checker_builtin_value_symbol(builtin))
    }
    ctx
}

// Collect direct ModuleImplFact entries from a module's own HIR (pre-prelude).
// A private inline mod does not publish a direct fact. If one of its types or
// traits is re-exported through a public facade, extract_exports instead adds
// that exact registry owner through the public type/trait closure.
fn impl_trait_name_same(left: Str?, right: Str?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => a == b,
        (none, none) => true,
        _ => false
    }
}
fn validate_impl_carriers(
    env: TypeEnv, decls: List<HDecl>
) {
    for decl in decls {
        match decl {
            HDecl::Impl {
                target_type, owner_ref, provider_ref, trait_ref, trait_name, methods, ..
            } => match find_impl_by_provider(
                env.trait_reg, target_type, trait_ref, provider_ref
            ) {
                some(owner) => {
                    if !impl_trait_name_same(owner.trait_name, trait_name) ||
                       !optional_symbol_ref_same(owner.trait_ref, trait_ref) ||
                       match owner.owner_ref {
                           some(registered) => !impl_owner_ref_same(
                               registered, owner_ref),
                           none => true
                       } {
                        panic("impl HIR: typed owner relation changed")
                    }
                    for method in methods {
                        match method {
                            HDecl::Fn { name, .. } => {
                                if !owner.method_schemes.contains_key(name) {
                                    panic("impl HIR: method is not owned by carrier")
                                }
                            },
                            _ => {}
                        }
                    }
                },
                none => panic("impl HIR: typed owner is missing")
            },
            HDecl::ModBlock { decls: inner, .. } =>
                validate_impl_carriers(env, inner),
            _ => {}
        }
    }
}

fn collect_module_impl_facts(
    env: TypeEnv, decls: List<HDecl>, is_top_level: Bool,
    mut facts: List<ModuleImplFact>
) {
    for decl in decls {
        match decl {
            HDecl::Impl {
                target_type, owner_ref, provider_ref, trait_ref, trait_name, methods, ..
            } => {
                let mut method_names: List<Str> = []
                let mut public_inherent_method_names: List<Str> = []
                for m in methods {
                    match m {
                        HDecl::Fn { name, is_pub, .. } => {
                            method_names.push(name)
                            if trait_ref.is_none() && is_pub {
                                public_inherent_method_names.push(name)
                            }
                        },
                        _ => {}
                    }
                }
                // An empty inherent impl exports no callable or evidence.
                if trait_name.is_some() || method_names.len() > 0 {
                    match find_impl_by_provider(
                        env.trait_reg, target_type, trait_ref, provider_ref
                    ) {
                        some(owner) => {
                            if !impl_trait_name_same(
                                    owner.trait_name, trait_name) ||
                               !optional_symbol_ref_same(
                                    owner.trait_ref, trait_ref) ||
                               match owner.owner_ref {
                                   some(registered) => !impl_owner_ref_same(
                                       registered, owner_ref),
                                   none => true
                               } {
                                panic("module impl fact: typed owner relation changed")
                            }
                            for method_name in method_names {
                                if !owner.method_schemes.contains_key(method_name) {
                                    panic("module impl fact: carrier method is not owned")
                                }
                            }
                            facts.push(ModuleImplFact {
                                target: target_type,
                                provider_ref: provider_ref,
                                trait_ref: trait_ref,
                                owner_ref: owner_ref,
                                method_names: method_names,
                                public_inherent_method_names:
                                    public_inherent_method_names,
                                is_top_level: is_top_level
                            })
                        },
                        none => panic(
                            "module impl fact: exact registered owner is not unique")
                    }
                }
            },
            HDecl::ModBlock { decls: mod_decls, is_pub, .. } => {
                if is_pub {
                    collect_module_impl_facts(
                        env, mod_decls, false, facts)
                }
            },
            _ => {}
        }
    }
}

pub fn check(program: Program, sink: CollectingSink) -> CheckResult {
    let file_key = single_namespace_file_key(program)
    let mut ctx = new_infer_ctx(sink, file_key, 0)
    match first_duplicate_direct_declaration(program) {
        some(duplicate) => {
            ctx.sink.report(duplicate_direct_declaration_diagnostic(duplicate))
            return failed_check_result(ctx, file_key)
        },
        none => {}
    }
    match reserved_type_declaration_diagnostic(program) {
        some(diagnostic) => {
            ctx.sink.report(diagnostic)
            return failed_check_result(ctx, file_key)
        },
        none => {}
    }
    let prelude_hdecls = load_prelude(ctx)
    install_struct_identity_ledger(
        ctx, file_key,
        resolve_single_namespace_plan(program))
    let inferred = some(infer_check(ctx, program)) catch { _ => none }
    if inferred.is_none() {
        if !ctx.sink.has_errors() {
            panic("checker: inference failed without a diagnostic")
        }
        return failed_check_result(ctx, file_key)
    }
    let hprogram = inferred.unwrap()
    let mut impl_facts: List<ModuleImplFact> = []
    validate_impl_carriers(ctx.env, hprogram.decls)
    collect_module_impl_facts(
        ctx.env, hprogram.decls, true, impl_facts)
    // Prepend prelude hdecls to the program's decls
    let mut all_decls = list_clone(prelude_hdecls)
    for d in hprogram.decls { all_decls.push(d) }
    // B-104 D7: lower `&&`/`||` to if-else (andor_lower), then B-104 D4:
    // first-class the dict evidence (static singleton set + local
    // constructions for dynamic wrapped dicts) — both before perceus/codegen.
    let derived_impls = hprogram.derived_impls
    validate_derived_impls(ctx.env, derived_impls)
    let assembled = HProgram { decls: all_decls, derived_impls: derived_impls, boxed_vars: hprogram.boxed_vars, static_dicts: [], extern_type_names: hprogram.extern_type_names, drop_types: hprogram.drop_types }
    let has_errors = ctx.sink.has_errors()
    let checked_program = if has_errors {
        assembled
    } else {
        lower_dicts(lower_andor(assembled), ctx.core_module_key)
    }
    let frozen = if has_errors { none } else { some(
        freeze_core_and_legacy_facts(
            ctx.core_module_key, ctx.core_module_order,
            checked_program, ctx.env,
            physical_nominal_inputs_for_core(ctx.env, []),
            file_key, "")) }
    CheckResult {
        program: checked_program,
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params,
        value_binding_kinds: map_clone(ctx.value_binding_kinds),
        value_symbols: map_clone(ctx.value_symbols),
        core_facts: frozen.map(fn(value) {
            frozen_core_and_legacy_core(value) }),
        legacy_facts: frozen.map(fn(value) {
            frozen_core_and_legacy_legacy(value) }),
        prelude_physical_owner_module_key: file_key,
        impl_facts: impl_facts
    }
}

struct NamespaceFrameAst {
    uses: List<UseDecl>,
    decls: List<Decl>
}

fn namespace_kind_name(namespace: NamespaceKind) -> Str {
    match namespace {
        NamespaceKind::Value => "value",
        NamespaceKind::Struct => "struct",
        NamespaceKind::Enum => "enum",
        NamespaceKind::TypeAlias => "type alias",
        NamespaceKind::Effect => "effect",
        NamespaceKind::EffectAlias => "effect alias",
        NamespaceKind::Trait => "trait"
    }
}

fn namespace_decl_span(decl: Decl) -> Span {
    match decl {
        Decl::Fn { span, .. } => span,
        Decl::Struct { span, .. } => span,
        Decl::Enum { span, .. } => span,
        Decl::Impl { span, .. } => span,
        Decl::Effect { span, .. } => span,
        Decl::Test { span, .. } => span,
        Decl::Trait { span, .. } => span,
        Decl::ExternFn { span, .. } => span,
        Decl::ExternType { span, .. } => span,
        Decl::TypeAlias { span, .. } => span,
        Decl::Const { span, .. } => span,
        Decl::ModBlock { span, .. } => span,
        Decl::EffectAlias { span, .. } => span,
        Decl::Delegate { span, .. } => span,
        Decl::AssocType { span, .. } => span
    }
}

fn find_namespace_frame(
    plan: ResolvedNamespacePlan, file_key: Str, frame_index: Int
) -> ModuleFramePlan? {
    for frame in plan.frames {
        if frame.file_key == file_key && frame.frame_index == frame_index {
            return some(frame)
        }
    }
    none
}

// Recover an inline frame through its exact parent frame and declaration
// index. Duplicate same-named ModBlocks therefore remain distinct AST sites.
fn find_namespace_frame_ast(
    program: Program, plan: ResolvedNamespacePlan,
    file_key: Str, frame_index: Int
) -> NamespaceFrameAst? {
    match find_namespace_frame(plan, file_key, frame_index) {
        none => none,
        some(frame) => {
            if frame.parent_frame_index < 0 {
                return some(NamespaceFrameAst {
                    uses: program.uses,
                    decls: program.decls
                })
            }
            match find_namespace_frame_ast(
                program, plan, file_key, frame.parent_frame_index) {
                none => none,
                some(parent) => match parent.decls.get(frame.decl_index) {
                    some(Decl::ModBlock { uses, decls, .. }) =>
                        some(NamespaceFrameAst { uses: uses, decls: decls }),
                    _ => none
                }
            }
        }
    }
}

fn namespace_issue_span(
    program: Program, plan: ResolvedNamespacePlan, site: AstSite
) -> Span {
    match find_namespace_frame_ast(
        program, plan, site.file_key, site.frame_index) {
        none => program.span,
        some(frame) => {
            if site.use_index >= 0 {
                match frame.uses.get(site.use_index) {
                    none => return program.span,
                    some(use_decl) => {
                        if site.item_index >= 0 {
                            match use_decl.imports {
                                UseImport::NamedItems { names } => {
                                    match names.get(site.item_index) {
                                        some(item) => return item.span,
                                        none => {}
                                    }
                                },
                                UseImport::Module => {}
                            }
                        }
                        return use_decl.path.span
                    }
                }
            }
            if site.use_index == -1 && site.item_index >= 0 {
                match frame.decls.get(site.item_index) {
                    some(decl) => return namespace_decl_span(decl),
                    none => {}
                }
            }
            program.span
        }
    }
}

fn report_namespace_plan_issues(
    mut ctx: InferCtx, module_key: Str,
    program: Program, plan: ResolvedNamespacePlan
) {
    for issue in plan.issues {
        if issue.site.file_key != module_key { continue }
        let span = namespace_issue_span(program, plan, issue.site)
        let namespace = namespace_kind_name(issue.namespace)
        let source_owner = nominal_display_name(issue.source_owner)
        match issue.kind {
            ImportIssueKind::RelativeOutOfScope => {
                let message = if issue.site.frame_index == 0 {
                    "Cannot use '${issue.source_name}::' at file level — relative paths are only supported inside mod blocks"
                } else {
                    "Cannot use 'super::' — relative path exceeds module nesting depth"
                }
                ctx.sink.report(make_diag(
                    E0705, Severity::SevError, message, span,
                    DiagnosticContext::OtherContext {
                        detail: some("relative path out of scope")
                    }))
            },
            ImportIssueKind::SourceFrameMissing => {
                ctx.sink.report(make_diag(
                    E0702, Severity::SevError,
                    "Module '${source_owner}' not found", span,
                    DiagnosticContext::OtherContext {
                        detail: some("source namespace frame not found")
                    }))
            },
            ImportIssueKind::SourceNameMissing => {
                let message = if issue.source_name == "" {
                    "Import from module '${source_owner}' does not name a symbol"
                } else {
                    "Symbol '${issue.source_name}' not found in module '${source_owner}'"
                }
                ctx.sink.report(make_diag(
                    E0703, Severity::SevError, message, span,
                    DiagnosticContext::OtherContext {
                        detail: some("source name not found")
                    }))
            },
            ImportIssueKind::AmbiguousBinding => {
                let mut related: List<Str> = []
                for payload in issue.related_owners {
                    related.push(nominal_display_name(payload))
                }
                let conflict = if related.len() == 2 {
                    "'${related.get(0).unwrap_or("")}' and '${related.get(1).unwrap_or("")}'"
                } else {
                    related.join(", ")
                }
                ctx.sink.report(make_diag(
                    E0707, Severity::SevError,
                    "Ambiguous ${namespace} name '${issue.local_name}': conflicting payloads ${conflict}",
                    span,
                    DiagnosticContext::OtherContext {
                        detail: some("ambiguous ${namespace} binding")
                    }))
            },
            ImportIssueKind::UnresolvedImportCycle => {
                let subject = if issue.local_name == "" {
                    ""
                } else {
                    " for '${issue.local_name}'"
                }
                ctx.sink.report(make_diag(
                    E0704, Severity::SevError,
                    "Unresolved ${namespace} import dependency SCC${subject} in module '${source_owner}'",
                    span,
                    DiagnosticContext::OtherContext {
                        detail: some("namespace import dependency SCC")
                    }))
            },
            ImportIssueKind::ReservedType => {
                ctx.sink.report(reserved_type_name_diagnostic(
                    issue.local_name, span))
            }
        }
    }
}

pub fn check_module(
    program: Program, module_key: Str, module_prefix: Str,
    module_order: Int, prelude_physical_owner_module_key: Str,
    namespace_plan: ResolvedNamespacePlan,
    module_exports: List<ModuleExports>, sink: CollectingSink
) -> CheckResult {
    if prelude_physical_owner_module_key == "" ||
       ((module_order == 0) !=
            (module_key == prelude_physical_owner_module_key)) {
        panic("project checker: prelude physical owner relation differs")
    }
    // Project compilation must have passed through build_module_graph, which
    // applies the same AST authority before constructing resolver frames.
    // Fail closed here without publishing a second diagnostic if an internal
    // caller bypasses that gate.
    match first_duplicate_direct_declaration(program) {
        some(_) => panic(
            "unreachable: project checker received duplicate direct declaration"),
        none => {}
    }
    if reserved_type_declaration_diagnostic(program).is_some() {
        panic(
            "unreachable: project checker received reserved builtin type declaration")
    }
    let mut ctx = new_infer_ctx(
        sink, module_key, module_order)
    let prelude_hdecls = load_prelude(ctx)
    inject_module_exports(ctx, module_exports)
    let _ = install_project_namespace_plan(ctx, module_key, namespace_plan)
    install_struct_identity_ledger(ctx, module_key, namespace_plan)
    report_namespace_plan_issues(ctx, module_key, program, namespace_plan)
    let inferred = some(check_module_identity(
        ctx, program, module_prefix, module_key)) catch { _ => none }
    if inferred.is_none() {
        if !ctx.sink.has_errors() {
            panic("project checker: inference failed without a diagnostic")
        }
        return failed_check_result(
            ctx, prelude_physical_owner_module_key)
    }
    let hprogram = inferred.unwrap()
    // Project-wide builtin derived descriptors have one physical carrier and
    // are assembled by compiler_mod only after every module has crossed the
    // dictionary-lowering boundary.  Per-module checking validates user
    // descriptors but must never publish builtin duplicates.
    validate_derived_impls(ctx.env, hprogram.derived_impls)
    let mut impl_facts: List<ModuleImplFact> = []
    validate_impl_carriers(ctx.env, hprogram.decls)
    collect_module_impl_facts(
        ctx.env, hprogram.decls, true, impl_facts)
    // Prepend prelude hdecls to the program's decls
    let mut all_decls: List<HDecl> = if module_order == 0 {
        list_clone(prelude_hdecls)
    } else { [] }
    for d in hprogram.decls { all_decls.push(d) }
    // B-104 D7 + D4: see check() above.
    let assembled = HProgram { decls: all_decls, derived_impls: hprogram.derived_impls, boxed_vars: hprogram.boxed_vars, static_dicts: [], extern_type_names: hprogram.extern_type_names, drop_types: hprogram.drop_types }
    let has_errors = ctx.sink.has_errors()
    let checked_program = if has_errors {
        assembled
    } else {
        lower_dicts(lower_andor(assembled), ctx.core_module_key)
    }
    let frozen = if has_errors { none } else { some(
        freeze_core_and_legacy_facts(
            ctx.core_module_key, ctx.core_module_order,
            checked_program, ctx.env,
            physical_nominal_inputs_for_core(ctx.env, module_exports),
            prelude_physical_owner_module_key, module_prefix)) }
    CheckResult {
        program: checked_program,
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params,
        value_binding_kinds: map_clone(ctx.value_binding_kinds),
        value_symbols: map_clone(ctx.value_symbols),
        core_facts: frozen.map(fn(value) {
            frozen_core_and_legacy_core(value) }),
        legacy_facts: frozen.map(fn(value) {
            frozen_core_and_legacy_legacy(value) }),
        prelude_physical_owner_module_key:
            prelude_physical_owner_module_key,
        impl_facts: impl_facts
    }
}

fn has_imported_struct_header(env: TypeEnv, value: StructDef) -> Bool {
    for entry in env.types.structs.entries() {
        if registered_nominal_ref_same(entry.1.owner_ref, value.owner_ref) {
            return true
        }
    }
    for entry in env.types.extern_structs.entries() {
        if registered_nominal_ref_same(entry.1.owner_ref, value.owner_ref) {
            return true
        }
    }
    false
}

fn has_imported_enum_header(env: TypeEnv, value: EnumDef) -> Bool {
    for entry in env.types.enums.entries() {
        if registered_nominal_ref_same(entry.1.owner_ref, value.owner_ref) {
            return true
        }
    }
    false
}

fn has_imported_effect_header(env: TypeEnv, value: EffectDef) -> Bool {
    for entry in env.types.effects.entries() {
        let existing = entry.1
        match (existing.owner_ref, value.owner_ref) {
            (some(left), some(right)) => if symbol_ref_same(left, right) {
                return true
            },
            _ => match (existing.handled_ref, value.handled_ref) {
                (some(left), some(right)) => if handled_effect_ref_same(
                        left, right) { return true },
                _ => {}
            }
        }
    }
    false
}

fn has_imported_trait_header(env: TypeEnv, value: TraitDef) -> Bool {
    for entry in env.trait_reg.traits.entries() {
        if registered_trait_ref_same(entry.1.owner_ref, value.owner_ref) {
            return true
        }
    }
    false
}

fn register_imported_struct_effect_headers(
    mut ctx: InferCtx, value: StructDef
) {
    if value.fields.len() != value.field_effect_schemas.len() {
        panic("effect header schema: imported struct census differs")
    }
    for schema in value.field_effect_schemas {
        publish_effect_header_schema(ctx.env, schema)
    }
}

fn register_imported_enum_effect_headers(
    mut ctx: InferCtx, value: EnumDef
) {
    if value.variants.len() != value.variant_field_refs.len() ||
       value.variants.len() != value.variant_field_effect_schemas.len() {
        panic("effect header registry: imported enum census differs")
    }
    let mut variant_index = 0
    while variant_index < value.variants.len() {
        let variant = value.variants.get(variant_index).unwrap()
        let refs = value.variant_field_refs.get(variant_index).unwrap()
        if variant.fields.len() != refs.len() ||
           variant.fields.len() != value.variant_field_effect_schemas.get(
                variant_index).unwrap().len() {
            panic("effect header registry: imported payload census differs")
        }
        let mut field_index = 0
        while field_index < variant.fields.len() {
            publish_effect_header_schema(
                ctx.env, value.variant_field_effect_schemas.get(
                    variant_index).unwrap().get(field_index).unwrap())
            field_index = field_index + 1
        }
        variant_index = variant_index + 1
    }
}

fn register_imported_effect_headers(
    mut ctx: InferCtx, value: EffectDef
) {
    for op in value.ops {
        let operation = match op.operation_ref {
            some(reference) => reference,
            none => panic("effect header registry: imported op lacks identity")
        }
        publish_effect_header_schema(ctx.env, op.effect_schema)
        let type_args = value.type_param_vars.map(fn(id) {
            Type::TypeVar { id: id, name: none }
        })
        register_callable_effect_header(
            ctx.env, effect_operation_ref_callable(operation),
            EffectRow { effects: [Effect::CustomEffect {
                reference: value.handled_ref.unwrap(), name: value.name,
                type_args: type_args
            }], tail: none })
    }
}

fn register_imported_trait_effect_headers(
    mut ctx: InferCtx, value: TraitDef
) {
    for method in value.methods {
        publish_effect_header_schema(ctx.env, method.effect_schema)
        match method.ty {
            Type::FnType { effects, .. } => register_callable_effect_header(
                ctx.env,
                make_named_executable_ref(
                    trait_method_ref_member(method.method_ref)),
                effects),
            _ => panic("effect header registry: trait method is not callable")
        }
    }
    for assoc in value.assoc_types {
        match assoc.default_type {
            some(_) => {
                publish_effect_header_schema(
                    ctx.env, match assoc.default_effect_schema {
                        some(schema) => schema,
                        none => panic(
                            "effect header schema: trait default schema is absent")
                    })
            },
            none => {}
        }
    }
}

fn inject_module_exports(mut ctx: InferCtx, exports: List<ModuleExports>) {
    // Canonical value payloads are the only source keys consumed by the
    // resolver plan. Export display keys are intentionally not hydrated:
    // same-leaf exports from unrelated modules may coexist, while each exact
    // value/constructor origin is installed once with a checker-local DefId.
    let mut hydrated_value_symbols: List<SymbolRef> = []
    for mod_ in exports {
        let mut sorted_values = mod_.values.entries()
        sorted_values.sort_by(compare_by_first)
        for entry in sorted_values {
            let (lookup_name, scheme) = entry
            let value_symbol = match mod_.value_symbols.get(lookup_name) {
                some(value) => value,
                none => panic("module export: value lacks exact SymbolRef")
            }
            if !hydrated_value_symbols.any(fn(existing) {
                    symbol_ref_same(existing, value_symbol)
                }) {
                let localized = localize_imported_type_scheme(
                    ctx.env, scheme)
                let payload = symbol_ref_canonical_payload(value_symbol)
                ctx.env.bind(payload, localized)
                record_value_origin(ctx, payload, payload)
                record_value_symbol_ref(ctx, payload, value_symbol)
                publish_effect_header_schema(
                    ctx.env, localized.effect_schema)
                match mod_.value_binding_kinds.get(lookup_name) {
                    some(kind) => {
                        record_value_binding_kind(ctx, payload, kind)
                    },
                    none => {}
                }
                match mod_.fn_mut_params.get(lookup_name) {
                    some(flags) => { ctx.fn_mut_params.insert(payload, flags) },
                    none => {}
                }
                hydrated_value_symbols.push(value_symbol)
            }
        }
        let mut sorted_types = mod_.types.entries()
        sorted_types.sort_by(compare_by_first)
        for entry in sorted_types {
            let (name, def) = entry
            match def {
                TypeDef::StructDef_(sdef) => {
                    if !has_imported_struct_header(ctx.env, sdef) {
                        let localized = localize_imported_struct_def(
                            ctx.env, sdef)
                        register_imported_struct_effect_headers(ctx, localized)
                        if localized.is_extern {
                            // Dependency hydration exposes only the raw ABI
                            // source. Namespace frames install visible names.
                            ctx.env.types.extern_structs.insert(
                                localized.name, localized)
                        } else {
                            ctx.env.types.structs.insert(
                                localized.name, localized)
                        }
                    }
                },
                TypeDef::EnumDef_(edef) => {
                    if !has_imported_enum_header(ctx.env, edef) {
                        let localized = localize_imported_enum_def(
                            ctx.env, edef)
                        register_imported_enum_effect_headers(ctx, localized)
                        ctx.env.types.enums.insert(
                            localized.name, localized)
                    }
                },
            }
        }
        let mut sorted_type_aliases = mod_.type_aliases.entries()
        sorted_type_aliases.sort_by(compare_by_first)
        for entry in sorted_type_aliases {
            let (_, adef) = entry
            ctx.env.types.type_aliases.insert(adef.name, adef)
        }
        let mut sorted_effects = mod_.effects.entries()
        sorted_effects.sort_by(compare_by_first)
        for entry in sorted_effects {
            let (name, effdef) = entry
            if !has_imported_effect_header(ctx.env, effdef) {
                let localized = localize_imported_effect_def(ctx.env, effdef)
                register_imported_effect_headers(ctx, localized)
                ctx.env.types.effects.insert(localized.name, localized)
            }
        }
        let mut sorted_aliases = mod_.effect_aliases.entries()
        sorted_aliases.sort_by(compare_by_first)
        for entry in sorted_aliases {
            let (name, adef) = entry
            ctx.env.types.effect_aliases.insert(adef.name, adef)
        }
        let mut sorted_traits = mod_.traits.entries()
        sorted_traits.sort_by(compare_by_first)
        for entry in sorted_traits {
            let (name, tdef) = entry
            if !has_imported_trait_header(ctx.env, tdef) {
                let localized = localize_imported_trait_def(ctx.env, tdef)
                register_imported_trait_effect_headers(ctx, localized)
                ctx.env.trait_reg.traits.insert(localized.name, localized)
            }
        }
        for impl_ in mod_.trait_impls {
            let already_hydrated = match impl_.provider_ref {
                some(provider) => match find_impl_by_provider(
                    ctx.env.trait_reg, impl_.target_type_name,
                    impl_.trait_ref, provider) {
                    some(existing) => impl_entry_exact_key_same(
                        existing, impl_),
                    none => false
                },
                none => false
            }
            if !already_hydrated {
                let localized = localize_imported_impl_entry(
                    ctx.env, impl_)
                match localized.trait_name {
                    some(trait_name) => match find_impl(
                        ctx.env.trait_reg,
                        localized.target_type_name, trait_name) {
                        some(existing) => {
                            if !impl_entry_exact_key_same(
                                    existing, localized) {
                                let _ = type_error(ctx.sink, E0504,
                                    "Duplicate impl '${nominal_display_name(trait_name)}' for '${nominal_display_name(localized.target_type_name)}' from distinct dependency origins",
                                    localized.span,
                                    DiagnosticContext::TraitError {
                                        detail: "duplicate imported target/trait implementation"
                                    })
                            }
                        },
                        none => {}
                    },
                    none => {}
                }
                add_impl(ctx.env.trait_reg, localized)
            }
        }
        let mut sorted_method_index = mod_.method_index.entries()
        sorted_method_index.sort_by(compare_by_first)
        for entry in sorted_method_index {
            let (type_name, method_index) = entry
            let mut sorted_methods = method_index.entries()
            sorted_methods.sort_by(compare_by_first)
            for method_entry in sorted_methods {
                let (method_name, method_ref) = method_entry
                let owner_ref = impl_method_ref_owner(method_ref)
                match find_impl_by_provider(
                    ctx.env.trait_reg, type_name,
                    impl_owner_ref_trait(owner_ref),
                    impl_owner_ref_provider(owner_ref)
                ) {
                    some(owner) => {
                        match owner.method_refs.get(method_name) {
                            some(expected) => if !impl_method_ref_same(
                                    expected, method_ref) {
                                panic("impl hydration: exact method changed")
                            },
                            none => panic(
                                "impl hydration: owner method identity is missing")
                        }
                        let core = match owner.method_schemes.get(method_name) {
                            some(found) => found,
                            none => panic(
                                "impl hydration: exported index has no owner core")
                        }
                        let _ = install_method_core(
                            ctx.env.trait_reg, ctx.sink,
                            type_name, method_name, core,
                            method_ref, owner.span)
                    },
                    none => panic(
                        "impl hydration: exported index owner is missing")
                }
            }
        }
        // Inject mut_methods
        let mut sorted_mut = mod_.mut_methods.entries()
        sorted_mut.sort_by(compare_by_first)
        for entry in sorted_mut {
            let (type_name, method_set) = entry
            match ctx.env.trait_reg.mut_methods.get(type_name) {
                some(existing) => {
                    for m in method_set.to_list() {
                        existing.insert(m)
                    }
                },
                none => {
                    let mut new_set: Set<Str> = set_new()
                    for m in method_set.to_list() {
                        new_set.insert(m)
                    }
                    ctx.env.trait_reg.mut_methods.insert(type_name, new_set)
                },
            }
        }
        // Inject fn_mut_params
        let mut sorted_fmp = mod_.fn_mut_params.entries()
        sorted_fmp.sort_by(compare_by_first)
        for entry in sorted_fmp {
            let (fn_name, flags) = entry
            ctx.fn_mut_params.insert(fn_name, flags)
        }
    }
}
