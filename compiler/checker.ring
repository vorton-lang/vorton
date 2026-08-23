use types::{Type, UNIT, nominal_display_name}
use ast::{Program, Decl, UseDecl, UseImport, Span, TypeParam, span_zero}
use hir::{HDecl, HStmt, HExpr, HProgram, HMatchArm, HStructFieldInit, ModuleImplFact,
    HStringInterpPart, HEffectHandler, ValueBindingKind,
    CHECKER_ONLY_EXTERN_CALLABLES,
    compare_by_first, is_user_drop_type, hexpr_type,
    map_index_helper_source_name, map_index_helper_identity,
    prelude_extern_identity,
    is_nullary_variant_ctor_ident}
use diagnostics::{Severity, DiagnosticContext, CollectingSink, new_collecting_sink, make_diag}
use env::{TypeEnv, TypeScheme, add_impl, find_impl,
    find_impl_by_provider, impl_entry_exact_key_same,
    optional_symbol_ref_same,
    install_method_core, assert_no_provisional_impl_owners}
use builtins::{register_builtins, register_hof_intrinsics,
    finalize_std_hof_fallbacks}
use infer_decl::{check as infer_check, check_module_identity, check_prelude_decl}
use dict_lower::{lower_dicts}
use andor_lower::{lower_andor}
use infer_ctx::{InferCtx, new_infer_ctx as new_base_infer_ctx,
    type_error, record_value_origin, record_variant_ctor_origin,
    record_value_binding_kind, install_project_namespace_plan,
    install_struct_identity_ledger, enter_struct_identity_root_frame,
    exit_struct_identity_frame, close_struct_identity_ledger}
use infer_register::{register_decl_public}
use exports::{ModuleExports, TypeDef}
use resolver::{ResolvedNamespacePlan, ModuleFramePlan, AstSite, ImportIssue,
    ImportIssueKind, NamespaceKind, first_duplicate_direct_declaration,
    duplicate_direct_declaration_diagnostic,
    single_namespace_file_key, resolve_single_namespace_plan,
    prelude_namespace_file_key, resolve_prelude_namespace_plan}
use codes::{E0504, E0702, E0703, E0704, E0705, E0707, E0801}
use parser::{parse}
use union_find::{UnionFind}

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
    // User-declared impl blocks with the canonical target identity resolved
    // during checking (while namespace frames were live). Collected from the
    // module's own HIR before prelude decls are prepended, so exports never
    // have to re-resolve an impl target against the rolled-back environment.
    pub impl_facts: List<ModuleImplFact>
}

fn duplicate_direct_declaration_error_result(ctx: InferCtx) -> CheckResult {
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

fn load_prelude(mut ctx: InferCtx) -> List<HDecl> {
    let mut prelude_hdecls: List<HDecl> = []
    match find_std_dir() {
        some(std_dir) => {
            // Phase 1: collect and register all prelude declarations
            let mut all_prelude_decls: List<Decl> = []
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
                    let prelude_plan = resolve_prelude_namespace_plan(
                        file_path, canonical_program)
                    install_struct_identity_ledger(
                        ctx, prelude_namespace_file_key(file_path), prelude_plan)
                    enter_struct_identity_root_frame(ctx)
                    for decl_index in 0..canonical_decls.len() {
                        let canonical_decl = canonical_decls.get(
                            decl_index).unwrap()
                        register_decl_public(ctx, canonical_decl, decl_index)
                        all_prelude_decls.push(canonical_decl)
                    }
                    exit_struct_identity_frame(ctx)
                    close_struct_identity_ledger(ctx)
                }
            }
            assert_no_provisional_impl_owners(ctx.env.trait_reg)
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
            for decl in all_prelude_decls {
                match decl {
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
            for decl in all_prelude_decls {
                match decl {
                    Decl::Struct { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::Enum { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::Trait { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
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
                            let result = some(check_prelude_decl(ctx, filtered_decl)) catch { _ => none }
                            match result {
                                some(hd) => { prelude_hdecls.push(hd) },
                                none => {}
                            }
                        }
                    },
                    Decl::Fn { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::ExternFn { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
                        match result {
                            some(HDecl::ExternFn {
                                name, abi_name, def_id, type_params, params,
                                return_type, effects, is_pub, span
                            }) => {
                                // A small number of compiler-owned extern
                                // bridges carry an unspellable exact origin on
                                // their DefId. Preserve it in HDecl while
                                // keeping the parsed ABI leaf separately.
                                let exact_name = match def_id {
                                    some(id) => match ctx.use_aliases.get(id) {
                                        some(origin) => origin,
                                        none => name
                                    },
                                    none => name
                                }
                                prelude_hdecls.push(HDecl::ExternFn {
                                    name: exact_name, abi_name: abi_name,
                                    def_id: def_id, type_params: type_params,
                                    params: params, return_type: return_type,
                                    effects: effects, is_pub: is_pub, span: span
                                })
                            },
                            some(_) => {},
                            none => {}
                        }
                    },
                    _ => {}
                }
            }
        },
        none => {
            finalize_std_hof_fallbacks(ctx.env, ctx.sink)
            assert_no_provisional_impl_owners(ctx.env.trait_reg)
        },
    }
    prelude_hdecls
}

fn new_infer_ctx(sink: CollectingSink) -> InferCtx {
    let mut ctx = new_base_infer_ctx(sink)
    register_builtins(ctx.env, sink)
    register_hof_intrinsics(ctx.env, sink)
    // These bindings are created only by register_builtins above. Record their
    // freshly allocated DefIds now; later same-spelled locals cannot inherit
    // this provenance. `some` remains on the independent variant-ctor path.
    for builtin in (CHECKER_ONLY_EXTERN_CALLABLES) {
        record_value_binding_kind(ctx, builtin, ValueBindingKind::ExternCallable)
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
                target_type, provider_ref, trait_ref, trait_name, methods, ..
            } => match find_impl_by_provider(
                env.trait_reg, target_type, trait_ref, provider_ref
            ) {
                some(owner) => {
                    if !impl_trait_name_same(owner.trait_name, trait_name) ||
                       !optional_symbol_ref_same(owner.trait_ref, trait_ref) {
                        panic("impl HIR: typed owner relation changed")
                    }
                    for method in methods {
                        match method {
                            HDecl::Fn { name, .. } |
                            HDecl::ExternFn { name, .. } => {
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
    allow_incomplete: Bool, mut facts: List<ModuleImplFact>
) {
    for decl in decls {
        match decl {
            HDecl::Impl {
                target_type, provider_ref, trait_ref, trait_name, methods, ..
            } => {
                let mut method_names: List<Str> = []
                for m in methods {
                    match m {
                        HDecl::Fn { name, .. } => method_names.push(name),
                        HDecl::ExternFn { name, .. } => method_names.push(name),
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
                                    owner.trait_ref, trait_ref) {
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
                                owner_origin: owner.origin,
                                method_names: method_names,
                                is_top_level: is_top_level
                            })
                        },
                        none => if !allow_incomplete {
                            panic("module impl fact: exact registered owner is not unique")
                        }
                    }
                }
            },
            HDecl::ModBlock { decls: mod_decls, is_pub, .. } => {
                if is_pub {
                    collect_module_impl_facts(
                        env, mod_decls, false, allow_incomplete, facts)
                }
            },
            _ => {}
        }
    }
}

pub fn check(program: Program, sink: CollectingSink) -> CheckResult {
    let mut ctx = new_infer_ctx(sink)
    match first_duplicate_direct_declaration(program) {
        some(duplicate) => {
            ctx.sink.report(duplicate_direct_declaration_diagnostic(duplicate))
            return duplicate_direct_declaration_error_result(ctx)
        },
        none => {}
    }
    let prelude_hdecls = load_prelude(ctx)
    install_struct_identity_ledger(
        ctx, single_namespace_file_key(program),
        resolve_single_namespace_plan(program))
    let hprogram = infer_check(ctx, program)
    let mut impl_facts: List<ModuleImplFact> = []
    validate_impl_carriers(ctx.env, hprogram.decls)
    collect_module_impl_facts(
        ctx.env, hprogram.decls, true, ctx.sink.has_errors(), impl_facts)
    // Prepend prelude hdecls to the program's decls
    let mut all_decls = list_clone(prelude_hdecls)
    for d in hprogram.decls { all_decls.push(d) }
    // B-104 D7: lower `&&`/`||` to if-else (andor_lower), then B-104 D4:
    // first-class the dict evidence (static singleton set + local
    // constructions for dynamic wrapped dicts) — both before perceus/codegen.
    let assembled = HProgram { decls: all_decls, derived_impls: hprogram.derived_impls, boxed_vars: hprogram.boxed_vars, static_dicts: [], extern_type_names: hprogram.extern_type_names, drop_types: hprogram.drop_types }
    let has_errors = ctx.sink.has_errors()
    // B-002p1: check for use-after-move on Drop types (before lowering)
    if !has_errors && assembled.drop_types.len() > 0 {
        check_drop_moves(assembled, ctx.sink)
    }
    let checked_program = if has_errors {
        assembled
    } else {
        lower_dicts(lower_andor(assembled))
    }
    CheckResult {
        program: checked_program,
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params,
        value_origins: map_clone(ctx.use_aliases),
        value_binding_kinds: map_clone(ctx.value_binding_kinds),
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
    namespace_plan: ResolvedNamespacePlan,
    module_exports: List<ModuleExports>, sink: CollectingSink
) -> CheckResult {
    // Project compilation must have passed through build_module_graph, which
    // applies the same AST authority before constructing resolver frames.
    // Fail closed here without publishing a second diagnostic if an internal
    // caller bypasses that gate.
    match first_duplicate_direct_declaration(program) {
        some(_) => panic(
            "unreachable: project checker received duplicate direct declaration"),
        none => {}
    }
    let mut ctx = new_infer_ctx(sink)
    let prelude_hdecls = load_prelude(ctx)
    inject_module_exports(ctx, module_exports)
    let _ = install_project_namespace_plan(ctx, module_key, namespace_plan)
    install_struct_identity_ledger(ctx, module_key, namespace_plan)
    report_namespace_plan_issues(ctx, module_key, program, namespace_plan)
    let hprogram = check_module_identity(ctx, program, module_prefix)
    let mut impl_facts: List<ModuleImplFact> = []
    validate_impl_carriers(ctx.env, hprogram.decls)
    collect_module_impl_facts(
        ctx.env, hprogram.decls, true, ctx.sink.has_errors(), impl_facts)
    // Prepend prelude hdecls to the program's decls
    let mut all_decls = list_clone(prelude_hdecls)
    for d in hprogram.decls { all_decls.push(d) }
    // B-104 D7 + D4: see check() above.
    let assembled = HProgram { decls: all_decls, derived_impls: hprogram.derived_impls, boxed_vars: hprogram.boxed_vars, static_dicts: [], extern_type_names: hprogram.extern_type_names, drop_types: hprogram.drop_types }
    let has_errors = ctx.sink.has_errors()
    // B-002p1: check for use-after-move on Drop types (before lowering)
    if !has_errors && assembled.drop_types.len() > 0 {
        check_drop_moves(assembled, ctx.sink)
    }
    let checked_program = if has_errors {
        assembled
    } else {
        lower_dicts(lower_andor(assembled))
    }
    CheckResult {
        program: checked_program,
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params,
        value_origins: map_clone(ctx.use_aliases),
        value_binding_kinds: map_clone(ctx.value_binding_kinds),
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
        let mut sorted_method_origins = mod_.method_origins.entries()
        sorted_method_origins.sort_by(compare_by_first)
        for entry in sorted_method_origins {
            let (type_name, origins) = entry
            let mut sorted_origins = origins.entries()
            sorted_origins.sort_by(compare_by_first)
            for origin_entry in sorted_origins {
                let (method_name, origin) = origin_entry
                match find_impl_by_provider(
                    ctx.env.trait_reg, type_name,
                    origin.trait_ref, origin.provider_ref
                ) {
                    some(owner) => {
                        if owner.origin != origin.origin {
                            panic("impl hydration: legacy origin changed")
                        }
                        let core = match owner.method_schemes.get(method_name) {
                            some(found) => found,
                            none => panic(
                                "impl hydration: exported index has no owner core")
                        }
                        let _ = install_method_core(
                            ctx.env.trait_reg, ctx.sink,
                            type_name, method_name, core, origin)
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

// ============================================================
// B-002p1: Move checker for Drop types
// Walks HIR in program order to detect use-after-move.
// Phase 1 simplification: no branch/loop analysis — any move
// in any branch marks the variable as consumed for all
// subsequent uses in the same function scope.
// ============================================================

fn check_drop_moves(program: HProgram, mut sink: CollectingSink) {
    for decl in program.decls {
        match decl {
            HDecl::Fn { body, .. } => {
                let mut consumed: Map<Str, Span> = map_new()
                check_moves_expr(body, consumed, program.drop_types, sink)
            },
            HDecl::Impl { methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { body, .. } => {
                            let mut consumed: Map<Str, Span> = map_new()
                            check_moves_expr(body, consumed, program.drop_types, sink)
                        },
                        _ => {}
                    }
                }
            },
            _ => {}
        }
    }
}

fn check_consumed(name: Str, ty: Type, span: Span, consumed: Map<Str, Span>, drop_types: Set<Str>, mut sink: CollectingSink) {
    if is_user_drop_type(ty, drop_types) {
        match consumed.get(name) {
            some(_) => {
                let _ = type_error(sink, E0801,
                    "use of moved value: '${name}'",
                    span, DiagnosticContext::OtherContext { detail: some("value was previously moved") })
            },
            none => {}
        }
    }
}

fn try_consume_ident(expr: HExpr, mut consumed: Map<Str, Span>, drop_types: Set<Str>) {
    // A fieldless variant is Ident-shaped but evaluates a fresh constructor on
    // every occurrence. It is not a binding that can become moved.
    if is_nullary_variant_ctor_ident(expr) { return }
    match expr {
        HExpr::Ident { name, ty, span, .. } => {
            if is_user_drop_type(ty, drop_types) {
                consumed.insert(name, span)
            }
        },
        _ => {}
    }
}

fn check_moves_expr(expr: HExpr, mut consumed: Map<Str, Span>, drop_types: Set<Str>, mut sink: CollectingSink) {
    match expr {
        HExpr::Ident { name, ty, span, .. } => {
            // Mirror try_consume_ident: repeated evaluation of a nullary ctor is
            // repeated fresh construction, never use-after-move.
            if is_nullary_variant_ctor_ident(expr) == false {
                check_consumed(name, ty, span, consumed, drop_types, sink)
            }
        },
        HExpr::Block { stmts, tail, .. } => {
            for s in stmts {
                check_moves_stmt(s, consumed, drop_types, sink)
            }
            match tail {
                some(t) => check_moves_expr(t, consumed, drop_types, sink),
                none => {}
            }
        },
        HExpr::Call { callee, args, .. } => {
            check_moves_expr(callee, consumed, drop_types, sink)
            for arg in args {
                check_moves_expr(arg, consumed, drop_types, sink)
                // After using a Drop-type arg, consume it (move into callee)
                try_consume_ident(arg, consumed, drop_types)
            }
        },
        HExpr::FieldAccess { receiver, .. } => {
            check_moves_expr(receiver, consumed, drop_types, sink)
        },
        HExpr::BinOp { left, right, .. } => {
            check_moves_expr(left, consumed, drop_types, sink)
            check_moves_expr(right, consumed, drop_types, sink)
        },
        HExpr::UnaryOp { operand, .. } => {
            check_moves_expr(operand, consumed, drop_types, sink)
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            check_moves_expr(condition, consumed, drop_types, sink)
            check_moves_expr(then_branch, consumed, drop_types, sink)
            match else_branch {
                some(eb) => check_moves_expr(eb, consumed, drop_types, sink),
                none => {}
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            check_moves_expr(scrutinee, consumed, drop_types, sink)
            for arm in arms {
                match arm.guard {
                    some(g) => check_moves_expr(g, consumed, drop_types, sink),
                    none => {}
                }
                check_moves_expr(arm.body, consumed, drop_types, sink)
            }
        },
        HExpr::StructLit { fields, spread, .. } => {
            for f in fields {
                check_moves_expr(f.value, consumed, drop_types, sink)
            }
            match spread {
                some(s) => check_moves_expr(s, consumed, drop_types, sink),
                none => {}
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for f in fields {
                check_moves_expr(f.value, consumed, drop_types, sink)
            }
            match spread {
                some(s) => check_moves_expr(s, consumed, drop_types, sink),
                none => {}
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for p in parts {
                match p {
                    HStringInterpPart::Expression(e) => check_moves_expr(e, consumed, drop_types, sink),
                    HStringInterpPart::Literal(_) => {}
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            check_moves_expr(body, consumed, drop_types, sink)
            for arm in arms {
                check_moves_expr(arm.body, consumed, drop_types, sink)
            }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            check_moves_expr(body, consumed, drop_types, sink)
            for h in handlers {
                check_moves_expr(h.body, consumed, drop_types, sink)
            }
        },
        HExpr::Lambda { body, .. } => {
            check_moves_expr(body, consumed, drop_types, sink)
        },
        HExpr::EffectOp { args, .. } => {
            for a in args { check_moves_expr(a, consumed, drop_types, sink) }
        },
        HExpr::RangeExpr { start, end, .. } => {
            check_moves_expr(start, consumed, drop_types, sink)
            check_moves_expr(end, consumed, drop_types, sink)
        },
        HExpr::ListLit { elements, .. } => {
            for e in elements { check_moves_expr(e, consumed, drop_types, sink) }
        },
        HExpr::TupleLit { elements, .. } => {
            for e in elements { check_moves_expr(e, consumed, drop_types, sink) }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            check_moves_expr(receiver, consumed, drop_types, sink)
            check_moves_expr(index, consumed, drop_types, sink)
        },
        HExpr::ReturnExpr { value, .. } => {
            match value {
                some(v) => check_moves_expr(v, consumed, drop_types, sink),
                none => {}
            }
        },
        HExpr::Clone { inner, .. } => {
            check_moves_expr(inner, consumed, drop_types, sink)
        },
        HExpr::UnsafeBlock { body, .. } => {
            check_moves_expr(body, consumed, drop_types, sink)
        },
        HExpr::DictConstruct { .. } => {},
        // Literals — no sub-expressions
        HExpr::IntLit { .. } => {},
        HExpr::FloatLit { .. } => {},
        HExpr::StrLit { .. } => {},
        HExpr::BoolLit { .. } => {},
    }
}

fn check_moves_stmt(stmt: HStmt, mut consumed: Map<Str, Span>, drop_types: Set<Str>, mut sink: CollectingSink) {
    match stmt {
        HStmt::Let { init, .. } => {
            check_moves_expr(init, consumed, drop_types, sink)
            // If init is a bare Ident of Drop type, consume the source
            try_consume_ident(init, consumed, drop_types)
        },
        HStmt::Var { init, .. } => {
            check_moves_expr(init, consumed, drop_types, sink)
            try_consume_ident(init, consumed, drop_types)
        },
        HStmt::Assign { target, value, .. } => {
            check_moves_expr(target, consumed, drop_types, sink)
            check_moves_expr(value, consumed, drop_types, sink)
        },
        HStmt::ExprStmt { expr, .. } => {
            check_moves_expr(expr, consumed, drop_types, sink)
        },
        HStmt::Return { value, .. } => {
            match value {
                some(v) => check_moves_expr(v, consumed, drop_types, sink),
                none => {}
            }
        },
        HStmt::While { condition, body, .. } => {
            check_moves_expr(condition, consumed, drop_types, sink)
            check_moves_expr(body, consumed, drop_types, sink)
        },
        HStmt::ForIn { iterable, body, .. } => {
            check_moves_expr(iterable, consumed, drop_types, sink)
            check_moves_expr(body, consumed, drop_types, sink)
        },
        HStmt::Break { .. } => {},
        HStmt::Continue { .. } => {},
        HStmt::LetDestructure { init, .. } => {
            check_moves_expr(init, consumed, drop_types, sink)
        },
        HStmt::IfLet { expr, then_block, else_block, .. } => {
            check_moves_expr(expr, consumed, drop_types, sink)
            check_moves_expr(then_block, consumed, drop_types, sink)
            match else_block {
                some(eb) => check_moves_expr(eb, consumed, drop_types, sink),
                none => {}
            }
        },
        HStmt::Drop { .. } => {}
    }
}
