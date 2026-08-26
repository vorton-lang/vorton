use types::{UNIT, BUILTIN_OPTION, nominal_display_name}
use ast::{Program, Decl, UseDecl, UseImport, Span, TypeParam, span_zero}
use hir::{HDecl, HProgram, ModuleImplFact, ValueBindingKind,
    compare_by_first,
    map_index_helper_source_name, map_index_helper_identity,
    prelude_extern_identity}
use diagnostics::{Severity, DiagnosticContext, CollectingSink, new_collecting_sink, make_diag}
use env::{TypeEnv, TypeScheme, add_impl, find_impl,
    find_impl_by_provider, impl_entry_exact_key_same,
    optional_symbol_ref_same, install_method_core,
    register_compiler_owned_extern_source,
    close_compiler_owned_extern_sources,
    compiler_owned_extern_symbol,
    compiler_owned_extern_should_publish_hdecl}
use builtins::{register_builtins, register_hof_intrinsics,
    finalize_std_hof_fallbacks,
    checker_only_builtin_values, checker_builtin_value_name,
    checker_builtin_value_symbol}
use derive::{validate_derived_impls}
use infer_decl::{check as infer_check, check_module_identity, check_prelude_decl}
use dict_lower::{lower_dicts}
use andor_lower::{lower_andor}
use infer_ctx::{InferCtx, new_infer_ctx as new_base_infer_ctx,
    type_error, record_value_origin, record_variant_ctor_origin,
    record_value_binding_kind, record_value_symbol_ref,
    install_project_namespace_plan,
    install_struct_identity_ledger, enter_struct_identity_root_frame,
    exit_struct_identity_frame, close_struct_identity_ledger}
use infer_register::{register_decl_public}
use exports::{ModuleExports, TypeDef}
use resolver::{ResolvedNamespacePlan, ModuleFramePlan, AstSite, ImportIssue,
    ImportIssueKind, NamespaceKind, first_duplicate_direct_declaration,
    duplicate_direct_declaration_diagnostic,
    single_namespace_file_key, resolve_single_namespace_plan,
    prelude_namespace_file_key, resolve_prelude_namespace_plan}
use codes::{E0504, E0702, E0703, E0704, E0705, E0707}
use parser::{parse}
use ir_identity::{SymbolRef, impl_owner_ref_same, impl_method_ref_owner,
    impl_owner_ref_trait, impl_owner_ref_provider, impl_method_ref_same,
    symbol_ref_canonical_payload, make_symbol_ref, namespace_value,
    variant_ref_member}
use union_find::{UnionFind}
use core_from_hir::{FrozenCoreAssemblyFacts}
use legacy_projection::{LegacyProjectionFacts}
use core_legacy_freeze::{freeze_core_and_legacy_facts,
    frozen_core_and_legacy_core, frozen_core_and_legacy_legacy}

pub struct CheckResult {
    pub program: HProgram,
    pub env: TypeEnv,
    pub fn_mut_params: Map<Str, List<Bool>>,
    // Exact lexical DefId -> final canonical value identity. Re-export
    // extraction follows this map instead of preserving intermediate aliases.
    pub value_origins: Map<Int, Str>,
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

fn duplicate_direct_declaration_error_result(
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
        value_origins: map_clone(ctx.use_aliases),
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
    ["io.ring", "iterator.ring", "list.ring", "map.ring", "set.ring", "str.ring", "num.ring", "result.ring", "fs.ring", "path.ring", "process.ring"]

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
            // Phase 2: compile declarations needed by native codegen. Top-level
            // ExternFn declarations also become HDecl metadata: unlike impl
            // extern methods, their first-class values need an exact
            // declaration identity -> ABI leaf mapping in both backends.
            for site in all_prelude_decls {
                let decl = site.decl
                match decl {
                    Decl::Struct { .. } => {
                        let result = some(check_prelude_decl(
                            ctx, decl, site.file_key, site.decl_index, none)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::Enum { .. } => {
                        let result = some(check_prelude_decl(
                            ctx, decl, site.file_key, site.decl_index, none)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::Trait { .. } => {
                        let result = some(check_prelude_decl(
                            ctx, decl, site.file_key, site.decl_index, none)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::Impl { target_type, type_params, trait_name, methods, span } => {
                        // Filter to only Fn methods — ExternFn methods are already handled
                        // by the runtime and cannot be looked up via check_extern_fn_decl
                        // because they are registered on impl owners, not the main scope.
                        let mut fn_methods: List<Decl> = []
                        for m in methods {
                            match m { Decl::Fn { .. } => { fn_methods.push(m) }, _ => {} }
                        }
                        if fn_methods.len() > 0 {
                            let filtered_decl = Decl::Impl {
                                target_type: target_type,
                                type_params: type_params,
                                trait_name: trait_name,
                                methods: fn_methods,
                                span: span
                            }
                            let result = some(check_prelude_decl(
                                ctx, filtered_decl,
                                site.file_key, site.decl_index, none)) catch { _ => none }
                            match result {
                                some(hd) => { prelude_hdecls.push(hd) },
                                none => {}
                            }
                        }
                    },
                    Decl::Fn { .. } => {
                        let result = some(check_prelude_decl(
                            ctx, decl, site.file_key, site.decl_index, none)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::ExternFn { name, .. } => {
                        let source = match site.source_symbol {
                            some(symbol) => symbol,
                            none => panic(
                                "compiler extern manifest: Phase 2 source symbol is absent")
                        }
                        let publish = match
                                compiler_owned_extern_should_publish_hdecl(
                                    ctx.env, source) {
                            some(value) => value,
                            none => true
                        }
                        if publish {
                            let result = some(check_prelude_decl(
                                ctx, decl, site.file_key, site.decl_index,
                                some(canonical_prelude_extern_symbol(
                                    ctx.env, source, name)))) catch { _ => none }
                            match result {
                                some(HDecl::ExternFn {
                                    name, abi_name, def_id, executable_ref,
                                    type_params, params,
                                    return_type, effects, resource_contract,
                                    handled_evidence_bindings, trait_bounds,
                                    is_pub, span
                                }) => {
                                    // The source spelling is diagnostic/ABI
                                    // metadata only. ExecutableRef is the sole
                                    // callable identity transported downstream.
                                    prelude_hdecls.push(HDecl::ExternFn {
                                        name: name, abi_name: abi_name,
                                        def_id: def_id,
                                        executable_ref: executable_ref,
                                        type_params: type_params,
                                        params: params, return_type: return_type,
                                        effects: effects,
                                        resource_contract: resource_contract,
                                        handled_evidence_bindings:
                                            handled_evidence_bindings,
                                        trait_bounds: trait_bounds,
                                        is_pub: is_pub, span: span
                                    })
                                },
                                some(_) => {},
                                none => {}
                            }
                        }
                    },
                    _ => {}
                }
            }
        },
        none => {
            finalize_std_hof_fallbacks(ctx.env, ctx.sink)
        },
    }
    prelude_hdecls
}

fn new_infer_ctx(
    sink: CollectingSink, module_key: Str, module_order: Int
) -> InferCtx {
    let mut ctx = new_base_infer_ctx(
        sink, module_key, module_order)
    register_builtins(ctx.env, sink)
    register_hof_intrinsics(ctx.env, sink)
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
            return duplicate_direct_declaration_error_result(ctx, file_key)
        },
        none => {}
    }
    let prelude_hdecls = load_prelude(ctx)
    install_struct_identity_ledger(
        ctx, file_key,
        resolve_single_namespace_plan(program))
    let hprogram = infer_check(ctx, program)
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
            file_key, "")) }
    CheckResult {
        program: checked_program,
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params,
        value_origins: map_clone(ctx.use_aliases),
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
    let mut ctx = new_infer_ctx(
        sink, module_key, module_order)
    let prelude_hdecls = load_prelude(ctx)
    inject_module_exports(ctx, module_exports)
    let _ = install_project_namespace_plan(ctx, module_key, namespace_plan)
    install_struct_identity_ledger(ctx, module_key, namespace_plan)
    report_namespace_plan_issues(ctx, module_key, program, namespace_plan)
    let hprogram = check_module_identity(
        ctx, program, module_prefix, module_key)
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
            prelude_physical_owner_module_key, module_prefix)) }
    CheckResult {
        program: checked_program,
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params,
        value_origins: map_clone(ctx.use_aliases),
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

fn inject_module_exports(mut ctx: InferCtx, exports: List<ModuleExports>) {
    // Canonical value payloads are the only source keys consumed by the
    // resolver plan. Export display keys are intentionally not hydrated:
    // same-leaf exports from unrelated modules may coexist, while each exact
    // value/constructor origin is installed once with a checker-local DefId.
    let mut hydrated_value_origins: Set<Str> = set_new()
    for mod_ in exports {
        let mut sorted_values = mod_.values.entries()
        sorted_values.sort_by(compare_by_first)
        for entry in sorted_values {
            let (lookup_name, scheme) = entry
            let value_origin = mod_.value_origins.get(lookup_name)
            let ctor_origin = mod_.variant_ctor_origins.get(lookup_name)
            let mut exact_origins: List<Str> = []
            match value_origin {
                some(origin) => { exact_origins.push(origin) },
                none => {}
            }
            match ctor_origin {
                some(origin) => {
                    if !exact_origins.contains(origin) {
                        exact_origins.push(origin)
                    }
                },
                none => {}
            }
            for origin in exact_origins {
                if !hydrated_value_origins.contains(origin) {
                    ctx.env.bind(origin, TypeScheme { ..scheme, def_id: none })
                    let ultimate = match value_origin {
                        some(value) => value,
                        none => origin
                    }
                    record_value_origin(ctx, origin, ultimate)
                    match mod_.value_binding_kinds.get(lookup_name) {
                        some(kind) => {
                            record_value_binding_kind(ctx, origin, kind)
                        },
                        none => {}
                    }
                    match ctor_origin {
                        some(ctor) => {
                            record_variant_ctor_origin(ctx, origin, ctor)
                        },
                        none => {}
                    }
                    match mod_.fn_mut_params.get(lookup_name) {
                        some(flags) => { ctx.fn_mut_params.insert(origin, flags) },
                        none => {}
                    }
                    hydrated_value_origins.insert(origin)
                }
            }
        }
        let mut sorted_types = mod_.types.entries()
        sorted_types.sort_by(compare_by_first)
        for entry in sorted_types {
            let (name, def) = entry
            match def {
                TypeDef::StructDef_(sdef) => {
                    if sdef.is_extern {
                        // Dependency hydration exposes only the raw ABI source.
                        // Named/wildcard imports install visible spellings via
                        // the project namespace frame; infer_decl snapshots
                        // their raw codegen identities before frame rollback.
                        ctx.env.types.extern_structs.insert(sdef.name, sdef)
                    } else {
                        ctx.env.types.structs.insert(sdef.name, sdef)
                    }
                },
                TypeDef::EnumDef_(edef) => {
                    ctx.env.types.enums.insert(edef.name, edef)
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
            ctx.env.types.effects.insert(effdef.name, effdef)
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
            ctx.env.trait_reg.traits.insert(tdef.name, tdef)
        }
        for impl_ in mod_.trait_impls {
            match impl_.trait_name {
                some(trait_name) => match find_impl(
                    ctx.env.trait_reg,
                    impl_.target_type_name, trait_name) {
                    some(existing) => {
                        if !impl_entry_exact_key_same(existing, impl_) {
                            let _ = type_error(ctx.sink, E0504,
                                "Duplicate impl '${nominal_display_name(trait_name)}' for '${nominal_display_name(impl_.target_type_name)}' from distinct dependency origins",
                                impl_.span, DiagnosticContext::TraitError {
                                    detail: "duplicate imported target/trait implementation"
                                })
                        }
                    },
                    none => {}
                },
                none => {}
            }
            add_impl(ctx.env.trait_reg, impl_)
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
