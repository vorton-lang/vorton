use types::{Type, Effect, EffectRow, RecordField, StructField, EnumVariant,
    OwnershipMetadata,
    CallableTransferLevel, OwnershipShape,
    UNIT, EMPTY_ROW, CALLABLE_UNKNOWN,
    CALLABLE_DYNAMIC_TERM_BASE,
    CALLABLE_SOURCE_BUILTIN, CALLABLE_SOURCE_ALIAS,
    fresh_ownership_term, with_callable_ownership_term,
    normalize_callable_ownership_descriptor,
    intern_callable_ownership_descriptor,
    callable_transfer_levels_equal,
    callable_interface_transfer_levels, callable_owning_transfer_levels,
    shadow_callable_result_role_spine,
    shadow_callable_param_ownership,
    shadow_callable_return_ownership,
    set_shadow_callable_result_role,
    set_shadow_callable_result_role_spine,
    record_shadow_callable_with_transfer_levels,
    nominal_display_name, types_equal}
use ast::{Program, Decl, UseDecl, UseImport, Span, TypeParam, span_zero}
use hir::{HDecl, HStmt, HExpr, HProgram, HMatchArm, HStructFieldInit, ModuleImplFact,
    HStringInterpPart, HEffectHandler, ValueBindingKind,
    CHECKER_ONLY_EXTERN_CALLABLES,
    compare_by_first, is_user_drop_type, hexpr_type,
    map_index_helper_source_name, map_index_helper_identity,
    prelude_extern_identity,
    is_nullary_variant_ctor_ident}
use diagnostics::{Severity, DiagnosticContext, CollectingSink, new_collecting_sink, make_diag}
use env::{TypeEnv, TypeScheme, SigDef, EffectDef, EffectOpDef,
    StructDef, EnumDef, TypeAliasDef, AssocTypeDef,
    ImplEntry, TraitDef, TraitMethodDef,
    new_type_env, add_impl, find_impl, install_method_scheme,
    impl_method_origin,
    register_exact_shadow_callable_scheme_with_transfer_levels,
    replace_exact_shadow_callable_scheme_with_transfer_levels}
use builtins::{register_builtins, register_hof_intrinsics}
use infer_decl::{check as infer_check, check_module_identity, check_prelude_decl}
use dict_lower::{lower_dicts}
use andor_lower::{lower_andor}
use infer_ctx::{InferCtx, type_error, record_value_origin, record_variant_ctor_origin,
    record_value_binding_kind, bind_exact_import_alias,
    install_project_namespace_plan}
use infer_register::{register_decl_public,
    exact_prelude_extern_ownership, exact_prelude_extern_source,
    exact_prelude_extern_result_role}
use exports::{ModuleExports, TypeDef}
use resolver::{ResolvedNamespacePlan, ModuleFramePlan, AstSite, ImportIssue,
    ImportIssueKind, NamespaceKind}
use codes::{E0504, E0702, E0703, E0704, E0705, E0707, E0801}
use parser::{parse}
use union_find::{UnionFind}
use unify::{empty_subst}

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
                    for decl in ast.decls {
                        let canonical_decl = canonicalize_prelude_decl(decl)
                        register_decl_public(ctx, canonical_decl)
                        all_prelude_decls.push(canonical_decl)
                    }
                }
            }
            // Install the source-level API spelling as an alias of the exact
            // canonical scheme/DefId. record_value_origin makes ordinary
            // explicit calls use the same backend-safe canonical identity too.
            let map_get_name = map_index_helper_source_name()
            let map_get_identity = map_index_helper_identity()
            let _ = bind_exact_import_alias(
                ctx, map_get_name, map_get_identity, true)
            // Phase 1 has finished, so duplicate std declarations now resolve
            // to their final exact DefIds. Give every top-level prelude extern
            // an unspellable semantic identity; later user fn/const bindings
            // receive distinct DefIds and cannot collide in backend registries.
            for decl in all_prelude_decls {
                match decl {
                    Decl::ExternFn { name, params, .. } => {
                        let scheme = match ctx.env.lookup(name) {
                            some(value) => value,
                            none => panic(
                                "unreachable: prelude extern registration is missing")
                        }
                        let exact_source = exact_prelude_extern_source(name)
                        let exact = if exact_source == CALLABLE_SOURCE_BUILTIN {
                            let exact_term = exact_prelude_extern_ownership(
                                name, params)
                            let exact_type = with_callable_ownership_term(
                                scheme.ty, exact_term)
                            let levels = if name == "ring_slot_dealloc" {
                                callable_interface_transfer_levels(
                                    ctx.env.types.ownership_metadata,
                                    exact_type)
                            } else {
                                callable_owning_transfer_levels(
                                    ctx.env.types.ownership_metadata,
                                    exact_type)
                            }
                            replace_exact_shadow_callable_scheme_with_transfer_levels(
                                ctx.env, TypeScheme { ..scheme, ty: exact_type },
                                exact_term, exact_source, none, levels)
                        } else {
                            scheme
                        }
                        if exact_source == CALLABLE_SOURCE_BUILTIN {
                            ctx.env.rebind(name, exact)
                        }
                        let exact_def_id = exact.def_id.unwrap_or(-1)
                        set_shadow_callable_result_role(
                            ctx.env.types.ownership_metadata,
                            exact_def_id,
                            exact_prelude_extern_result_role(name))
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
                        // because they're registered in impl_methods_map, not the main scope.
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
        none => {},
    }
    prelude_hdecls
}

fn new_infer_ctx(sink: CollectingSink) -> InferCtx {
    let mut env = new_type_env()
    register_builtins(env, sink)
    register_hof_intrinsics(env, sink)

    let mut ctx = InferCtx {
        env: env,
        subst: empty_subst(),
        sink: sink,
        type_param_scope: map_new(),
        current_fn_return_type: none,
        current_fn_bounds: [],
        fn_bounds_stack: [],
        pending_dict_obligations: [],
        loop_depth: 0,
        mod_path_stack: [],
        use_aliases: map_new(),
        value_binding_kinds: map_new(),
        next_shadow_callable_ordinal: 0,
        boxed_vars: set_new(),
        lambda_depth: 0,
        var_lambda_depth: map_new(),
        fn_mut_params: map_new(),
        file_extern_types: set_new(),
        effect_default_deps: map_new(),
        qualified_assoc_scope: map_new(),
        rebind_assoc_provenance: map_new(),
        fn_defaults: map_new(),
        fn_min_arity: map_new(),
        mod_unsafe_allowed: false,
        drop_types: set_new(),
        project_namespace_file_key: none,
        project_namespace_root_frame: none,
        project_namespace_child_frames: map_new(),
        project_namespace_bindings: map_new(),
        project_namespace_ctor_enums: map_new(),
        project_namespace_frame_stack: []
    }
    // These bindings are created only by register_builtins above. Record their
    // freshly allocated DefIds now; later same-spelled locals cannot inherit
    // this provenance. `some` remains on the independent variant-ctor path.
    for builtin in (CHECKER_ONLY_EXTERN_CALLABLES) {
        record_value_binding_kind(ctx, builtin, ValueBindingKind::ExternCallable)
    }
    ctx
}

// Collect ModuleImplFact entries from a module's own HIR (pre-prelude).
// Non-public inline mods are skipped: their impls were never exported by the
// AST-walking extractor either, so consumers cannot observe those methods.
fn collect_module_impl_facts(
    decls: List<HDecl>, is_top_level: Bool, mut facts: List<ModuleImplFact>
) {
    for decl in decls {
        match decl {
            HDecl::Impl { target_type, trait_name, methods, .. } => {
                let mut method_names: List<Str> = []
                for m in methods {
                    match m {
                        HDecl::Fn { name, .. } => method_names.push(name),
                        _ => {}
                    }
                }
                facts.push(ModuleImplFact {
                    target: target_type,
                    is_trait_impl: trait_name.is_some(),
                    method_names: method_names,
                    is_top_level: is_top_level
                })
            },
            HDecl::ModBlock { decls: mod_decls, is_pub, .. } => {
                if is_pub {
                    collect_module_impl_facts(mod_decls, false, facts)
                }
            },
            _ => {}
        }
    }
}

pub fn check(program: Program, sink: CollectingSink) -> CheckResult {
    let mut ctx = new_infer_ctx(sink)
    let prelude_hdecls = load_prelude(ctx)
    let hprogram = infer_check(ctx, program)
    let mut impl_facts: List<ModuleImplFact> = []
    collect_module_impl_facts(hprogram.decls, true, impl_facts)
    // Prepend prelude hdecls to the program's decls
    let mut all_decls = list_clone(prelude_hdecls)
    for d in hprogram.decls { all_decls.push(d) }
    // B-104 D7: lower `&&`/`||` to if-else (andor_lower), then B-104 D4:
    // first-class the dict evidence (static singleton set + local
    // constructions for dynamic wrapped dicts) — both before perceus/codegen.
    let assembled = HProgram { decls: all_decls, derived_impls: hprogram.derived_impls, boxed_vars: hprogram.boxed_vars, static_dicts: [], extern_type_names: hprogram.extern_type_names, drop_types: hprogram.drop_types, ownership_metadata: hprogram.ownership_metadata }
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
        NamespaceKind::Trait => "trait",
        NamespaceKind::Sig => "sig"
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
        Decl::Sig { span, .. } => span,
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
    let mut ctx = new_infer_ctx(sink)
    let prelude_hdecls = load_prelude(ctx)
    inject_module_exports(ctx, module_exports)
    let _ = install_project_namespace_plan(ctx, module_key, namespace_plan)
    report_namespace_plan_issues(ctx, module_key, program, namespace_plan)
    let hprogram = check_module_identity(ctx, program, module_prefix)
    let mut impl_facts: List<ModuleImplFact> = []
    collect_module_impl_facts(hprogram.decls, true, impl_facts)
    // Prepend prelude hdecls to the program's decls
    let mut all_decls = list_clone(prelude_hdecls)
    for d in hprogram.decls { all_decls.push(d) }
    // B-104 D7 + D4: see check() above.
    let assembled = HProgram { decls: all_decls, derived_impls: hprogram.derived_impls, boxed_vars: hprogram.boxed_vars, static_dicts: [], extern_type_names: hprogram.extern_type_names, drop_types: hprogram.drop_types, ownership_metadata: hprogram.ownership_metadata }
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

fn report_hydrated_method_collision(
    mut ctx: InferCtx, target_type: Str, method_name: Str, span: Span
) {
    let _ = type_error(ctx.sink, E0504,
        "Ambiguous method '${method_name}' on '${nominal_display_name(target_type)}': dependency exports contain distinct implementation origins",
        span, DiagnosticContext::TraitError {
            detail: "same-origin re-exports dedupe, distinct origins collide"
        })
}

fn shadow_bool_lists_equal(a: List<Bool>, b: List<Bool>) -> Bool {
    if a.len() != b.len() { return false }
    let mut index = 0
    while index < a.len() {
        if a.get(index) != b.get(index) { return false }
        index = index + 1
    }
    true
}

fn shadow_role_spines_equal(a: List<Int>?, b: List<Int>?) -> Bool {
    match (a, b) {
        (some(left), some(right)) => {
            if left.len() != right.len() { return false }
            let mut index = 0
            while index < left.len() {
                if left.get(index) != right.get(index) { return false }
                index = index + 1
            }
            true
        },
        (none, none) => true,
        _ => false
    }
}

fn shadow_shapes_equal(a: OwnershipShape, b: OwnershipShape) -> Bool {
    if a.direct_drop != b.direct_drop || a.may_own != b.may_own ||
       a.param_deps.len() != b.param_deps.len() {
        return false
    }
    let mut index = 0
    while index < a.param_deps.len() {
        if a.param_deps.get(index) != b.param_deps.get(index) {
            return false
        }
        index = index + 1
    }
    true
}

fn shadow_transfer_spines_semantically_equal(
    local_metadata: OwnershipMetadata,
    local_levels: List<CallableTransferLevel>,
    exported_metadata: OwnershipMetadata,
    exported_levels: List<CallableTransferLevel>
) -> Bool {
    if local_levels.len() != exported_levels.len() { return false }
    let mut level_index = 0
    while level_index < local_levels.len() {
        match (local_levels.get(level_index),
               exported_levels.get(level_index)) {
            (some(local), some(exported)) => {
                if !shadow_bool_lists_equal(
                        local.force_params, exported.force_params) ||
                   shadow_callable_return_ownership(
                        local_metadata, local.ownership_term) !=
                   shadow_callable_return_ownership(
                        exported_metadata, exported.ownership_term) {
                    return false
                }
                let mut param_index = 0
                while param_index < local.force_params.len() {
                    if shadow_callable_param_ownership(
                            local_metadata, local.ownership_term,
                            param_index) !=
                       shadow_callable_param_ownership(
                            exported_metadata, exported.ownership_term,
                            param_index) {
                        return false
                    }
                    param_index = param_index + 1
                }
            },
            _ => return false
        }
        level_index = level_index + 1
    }
    true
}

fn canonical_shadow_alias_producer(
    metadata: OwnershipMetadata, def_id: Int, mut visited: Set<Int>
) -> Int {
    if visited.contains(def_id) {
        panic("unreachable: shadow alias producer cycle at DefId ${def_id}")
    }
    visited.insert(def_id)
    let state = match metadata.callable_state_by_def_id.get(def_id) {
        some(value) => value,
        none => panic("unreachable: shadow alias DefId ${def_id} has no state")
    }
    if state.source != CALLABLE_SOURCE_ALIAS { return def_id }
    let producer = match state.producer_def_id {
        some(value) => value,
        none => panic("unreachable: shadow alias DefId ${def_id} has no producer")
    }
    let producer_state = match metadata.callable_state_by_def_id.get(producer) {
        some(value) => value,
        none => panic("unreachable: shadow alias producer DefId ${producer} has no state")
    }
    if !metadata.callable_by_def_id.contains_key(def_id) ||
       !metadata.callable_by_def_id.contains_key(producer) ||
       !metadata.callable_result_role_spine_by_def_id.contains_key(def_id) ||
       !metadata.callable_result_role_spine_by_def_id.contains_key(producer) {
        panic("unreachable: shadow alias producer contract is incomplete")
    }
    if metadata.callable_by_def_id.get(def_id) !=
           metadata.callable_by_def_id.get(producer) ||
       state.arity != producer_state.arity ||
       !callable_transfer_levels_equal(
            state.transfer_levels, producer_state.transfer_levels) ||
       !shadow_role_spines_equal(
            metadata.callable_result_role_spine_by_def_id.get(def_id),
            metadata.callable_result_role_spine_by_def_id.get(producer)) {
        panic("unreachable: shadow alias wrapper differs from exact producer")
    }
    canonical_shadow_alias_producer(metadata, producer, visited)
}

fn shadow_producers_semantically_equal_inner(
    local_metadata: OwnershipMetadata, local_def_id: Int?,
    exported_metadata: OwnershipMetadata, exported_def_id: Int?,
    mut local_seen: Set<Int>, mut exported_seen: Set<Int>
) -> Bool {
    match (local_def_id, exported_def_id) {
        (none, none) => true,
        (some(local_id), some(exported_id)) => {
            let canonical_local = canonical_shadow_alias_producer(
                local_metadata, local_id, set_new())
            let canonical_exported = canonical_shadow_alias_producer(
                exported_metadata, exported_id, set_new())
            if local_seen.contains(canonical_local) ||
               exported_seen.contains(canonical_exported) {
                panic("unreachable: shadow canonical producer cycle")
            }
            local_seen.insert(canonical_local)
            exported_seen.insert(canonical_exported)
            let local_state = match local_metadata.
                callable_state_by_def_id.get(canonical_local) {
                some(value) => value,
                none => return false
            }
            let exported_state = match exported_metadata.
                callable_state_by_def_id.get(canonical_exported) {
                some(value) => value,
                none => return false
            }
            if local_state.source != exported_state.source ||
               local_state.arity != exported_state.arity ||
               !shadow_transfer_spines_semantically_equal(
                    local_metadata, local_state.transfer_levels,
                    exported_metadata, exported_state.transfer_levels) ||
                !shadow_role_spines_equal(
                    local_metadata.callable_result_role_spine_by_def_id.get(
                        canonical_local),
                    exported_metadata.callable_result_role_spine_by_def_id.get(
                        canonical_exported)) {
                return false
            }
            shadow_producers_semantically_equal_inner(
                local_metadata, local_state.producer_def_id,
                exported_metadata, exported_state.producer_def_id,
                local_seen, exported_seen)
        },
        _ => false
    }
}

fn shadow_producers_semantically_equal(
    local_metadata: OwnershipMetadata, local_def_id: Int?,
    exported_metadata: OwnershipMetadata, exported_def_id: Int?
) -> Bool {
    shadow_producers_semantically_equal_inner(
        local_metadata, local_def_id,
        exported_metadata, exported_def_id,
        set_new(), set_new())
}

fn merge_imported_shadow_shapes(
    mut ctx: InferCtx, metadata: OwnershipMetadata
) {
    let mut entries = metadata.ownership_shapes.entries()
    entries.sort_by(compare_by_first)
    for entry in entries {
        let (name, shape) = entry
        match ctx.env.types.ownership_metadata.ownership_shapes.get(name) {
            some(existing) => {
                if !shadow_shapes_equal(existing, shape) {
                    panic("unreachable: same nominal shadow ownership shape differs")
                }
            },
            none => ctx.env.types.ownership_metadata.ownership_shapes.insert(
                name, shape)
        }
    }
}

fn hydrate_shadow_term(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    term: Int, mut term_remap: Map<Int, Int>
) -> Int {
    if term < 0 {
        let descriptor = match exported.callable_descriptors.get(term) {
            some(value) => value,
            none => panic("unreachable: exported callable descriptor was stripped")
        }
        return intern_callable_ownership_descriptor(
            ctx.env.types.ownership_metadata, descriptor)
    }
    if term >= 0 && term < CALLABLE_DYNAMIC_TERM_BASE {
        return term
    }
    match term_remap.get(term) {
        some(local) => local,
        none => {
            let local = fresh_ownership_term(
                ctx.env.types.ownership_metadata)
            match exported.callable_descriptors.get(term) {
                some(descriptor) => {
                    ctx.env.types.ownership_metadata.callable_descriptors.insert(
                        local,
                        normalize_callable_ownership_descriptor(descriptor))
                },
                none => {}
            }
            term_remap.insert(term, local)
            local
        }
    }
}

fn hydrate_shadow_transfer_levels(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    levels: List<CallableTransferLevel>,
    mut term_remap: Map<Int, Int>
) -> List<CallableTransferLevel> {
    let mut result: List<CallableTransferLevel> = []
    for level in levels {
        let mut forces: List<Bool> = []
        for force in level.force_params { forces.push(force) }
        result.push(CallableTransferLevel {
            ownership_term: hydrate_shadow_term(
                ctx, exported, level.ownership_term, term_remap),
            force_params: forces
        })
    }
    result
}

fn hydrate_shadow_metadata_identity(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    exported_def_id: Int, mut term_remap: Map<Int, Int>,
    mut def_id_remap: Map<Int, Int>
) -> Int {
    match def_id_remap.get(exported_def_id) {
        some(local) => return local,
        none => {}
    }
    let state = match exported.callable_state_by_def_id.get(exported_def_id) {
        some(value) => value,
        none => panic("unreachable: exported producer metadata was stripped")
    }
    let exported_term = exported.callable_by_def_id.get(
        exported_def_id).unwrap()
    let local_def_id = ctx.env.fresh_def_id()
    def_id_remap.insert(exported_def_id, local_def_id)
    let local_producer = match state.producer_def_id {
        some(producer) => some(hydrate_shadow_metadata_identity(
            ctx, exported, producer, term_remap, def_id_remap)),
        none => none
    }
    let local_term = hydrate_shadow_term(
        ctx, exported, exported_term, term_remap)
    let levels = hydrate_shadow_transfer_levels(
        ctx, exported, state.transfer_levels, term_remap)
    record_shadow_callable_with_transfer_levels(
        ctx.env.types.ownership_metadata,
        local_def_id, local_term, state.source, state.arity,
        local_producer, levels)
    set_shadow_callable_result_role_spine(
        ctx.env.types.ownership_metadata, local_def_id,
        exported.callable_result_role_spine_by_def_id.get(
            exported_def_id).unwrap())
    local_def_id
}

fn hydrate_shadow_effect(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    eff: Effect, mut term_remap: Map<Int, Int>
) -> Effect {
    match eff {
        Effect::FailEffect { error_type } => Effect::FailEffect {
            error_type: hydrate_shadow_type(
                ctx, exported, error_type, term_remap)
        },
        Effect::MutEffect { state_type } => Effect::MutEffect {
            state_type: hydrate_shadow_type(
                ctx, exported, state_type, term_remap)
        },
        Effect::CustomEffect { name, type_args } => Effect::CustomEffect {
            name: name,
            type_args: type_args.map(fn(arg) {
                hydrate_shadow_type(ctx, exported, arg, term_remap)
            })
        },
        Effect::IoEffect => eff,
        Effect::UnsafeEffect => eff
    }
}

fn hydrate_shadow_row(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    row: EffectRow, mut term_remap: Map<Int, Int>
) -> EffectRow {
    EffectRow {
        effects: row.effects.map(fn(eff) {
            hydrate_shadow_effect(ctx, exported, eff, term_remap)
        }),
        tail: row.tail
    }
}

fn hydrate_shadow_type(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    ty: Type, mut term_remap: Map<Int, Int>
) -> Type {
    match ty {
        Type::FnType { params, return_type, effects, ownership_term } =>
            Type::FnType {
                params: params.map(fn(param) {
                    hydrate_shadow_type(ctx, exported, param, term_remap)
                }),
                return_type: hydrate_shadow_type(
                    ctx, exported, return_type, term_remap),
                effects: hydrate_shadow_row(
                    ctx, exported, effects, term_remap),
                ownership_term: hydrate_shadow_term(
                    ctx, exported, ownership_term, term_remap)
            },
        Type::StructType { name, type_params } => Type::StructType {
            name: name,
            type_params: type_params.map(fn(param) {
                hydrate_shadow_type(ctx, exported, param, term_remap)
            })
        },
        Type::EnumType { name, type_params } => Type::EnumType {
            name: name,
            type_params: type_params.map(fn(param) {
                hydrate_shadow_type(ctx, exported, param, term_remap)
            })
        },
        Type::GenericType { base, args } => Type::GenericType {
            base: hydrate_shadow_type(ctx, exported, base, term_remap),
            args: args.map(fn(arg) {
                hydrate_shadow_type(ctx, exported, arg, term_remap)
            })
        },
        Type::RecordType { fields, tail, tail_name } => Type::RecordType {
            fields: fields.map(fn(field) { RecordField {
                name: field.name,
                ty: hydrate_shadow_type(
                    ctx, exported, field.ty, term_remap)
            } }),
            tail: tail, tail_name: tail_name
        },
        Type::EffectRowType { effects, tail } => Type::EffectRowType {
            effects: effects.map(fn(eff) {
                hydrate_shadow_effect(ctx, exported, eff, term_remap)
            }),
            tail: tail
        },
        Type::TupleType { elements } => Type::TupleType {
            elements: elements.map(fn(element) {
                hydrate_shadow_type(ctx, exported, element, term_remap)
            })
        },
        Type::PtrType { pointee } => Type::PtrType {
            pointee: hydrate_shadow_type(
                ctx, exported, pointee, term_remap)
        },
        _ => ty
    }
}

fn hydrate_shadow_struct_def(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    def: StructDef, mut term_remap: Map<Int, Int>
) -> StructDef {
    StructDef {
        ..def,
        fields: def.fields.map(fn(field) { StructField {
            ..field,
            ty: hydrate_shadow_type(
                ctx, exported, field.ty, term_remap)
        } })
    }
}

fn hydrate_shadow_enum_def(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    def: EnumDef, mut term_remap: Map<Int, Int>
) -> EnumDef {
    EnumDef {
        ..def,
        variants: def.variants.map(fn(variant) { EnumVariant {
            ..variant,
            fields: variant.fields.map(fn(field) {
                hydrate_shadow_type(ctx, exported, field, term_remap)
            })
        } })
    }
}

fn shadow_value_callable_view(
    metadata: OwnershipMetadata, scheme: TypeScheme,
    kind: ValueBindingKind?
) -> TypeScheme {
    match kind {
        some(ValueBindingKind::ConstGetter) => {
            let def_id = match scheme.def_id {
                some(id) => id,
                none => panic("unreachable: const getter has no exact DefId")
            }
            let term = match metadata.callable_by_def_id.get(def_id) {
                some(value) => value,
                none => panic("unreachable: const getter metadata was stripped")
            }
            TypeScheme {
                ..scheme,
                ty: Type::FnType {
                    params: [], return_type: scheme.ty,
                    effects: EMPTY_ROW, ownership_term: term
                }
            }
        },
        _ => scheme
    }
}

// Hydrate one foreign callable onto an already chosen local DefId.  Dynamic
// ownership terms are checker-local and therefore remapped independently of
// source DefIds; canonical terms remain stable.  No spelling is consulted.
fn hydrate_exact_shadow_callable(
    mut ctx: InferCtx, exported: OwnershipMetadata,
    scheme: TypeScheme, exact_local_def_id: Int?,
    producer_def_id: Int?, mut term_remap: Map<Int, Int>,
    mut def_id_remap: Map<Int, Int>
) -> TypeScheme {
    let exported_def_id = match scheme.def_id {
        some(id) => id,
        none => panic("unreachable: exported callable has no exact DefId")
    }
    let state = match exported.callable_state_by_def_id.get(exported_def_id) {
        some(value) => value,
        none => panic("unreachable: exported callable metadata was stripped")
    }
    let exported_term = match exported.callable_by_def_id.get(exported_def_id) {
        some(value) => value,
        none => panic("unreachable: exported callable contract was stripped")
    }
    let params = match scheme.ty {
        Type::FnType { params, .. } => params,
        _ => panic("unreachable: exported callable scheme is not a function")
    }
    if state.arity != params.len() || state.transfer_levels.len() == 0 ||
       !exported.callable_result_role_by_def_id.contains_key(exported_def_id) ||
       !exported.returned_callable_result_role_by_def_id.contains_key(
            exported_def_id) ||
       !exported.callable_result_role_spine_by_def_id.contains_key(
            exported_def_id) {
        panic("unreachable: exported callable shadow metadata is incomplete")
    }
    let direct_transfer = state.transfer_levels.first().unwrap()
    if direct_transfer.ownership_term != exported_term ||
       direct_transfer.force_params.len() != params.len() {
        panic("unreachable: exported callable transfer metadata differs")
    }

    let hydrated_type = hydrate_shadow_type(
        ctx, exported, scheme.ty, term_remap)
    let local_term = match hydrated_type {
        Type::FnType { ownership_term, .. } => ownership_term,
        _ => panic("unreachable: hydrated callable is not a function")
    }
    let local_def_id = match (exact_local_def_id,
                              def_id_remap.get(exported_def_id)) {
        (some(id), some(existing)) => {
            if id != existing {
                panic("unreachable: imported callable DefId mapping drifted")
            }
            id
        },
        (some(id), none) => {
            def_id_remap.insert(exported_def_id, id)
            id
        },
        (none, some(existing)) => existing,
        (none, none) => {
            let id = ctx.env.fresh_def_id()
            def_id_remap.insert(exported_def_id, id)
            id
        }
    }
    let hydrated_producer = match state.producer_def_id {
        some(producer) => some(hydrate_shadow_metadata_identity(
            ctx, exported, producer, term_remap, def_id_remap)),
        none => none
    }
    match producer_def_id {
        some(expected) => if hydrated_producer != some(expected) {
            panic("unreachable: imported callable producer mapping differs")
        },
        none => {}
    }
    let hydrated_levels = hydrate_shadow_transfer_levels(
        ctx, exported, state.transfer_levels, term_remap)
    let exact = register_exact_shadow_callable_scheme_with_transfer_levels(
        ctx.env,
        TypeScheme {
            ..scheme,
            ty: with_callable_ownership_term(hydrated_type, local_term),
            def_id: some(local_def_id)
        },
        state.source, hydrated_producer, hydrated_levels)
    set_shadow_callable_result_role_spine(
        ctx.env.types.ownership_metadata, local_def_id,
        exported.callable_result_role_spine_by_def_id.get(
            exported_def_id).unwrap())
    exact
}

fn assert_same_origin_shadow_callable(
    ctx: InferCtx, exported: OwnershipMetadata,
    local_scheme: TypeScheme, exported_scheme: TypeScheme
) {
    if !types_equal(local_scheme.ty, exported_scheme.ty) {
        panic("unreachable: same-origin imported callable type differs")
    }
    let local_def_id = local_scheme.def_id.unwrap_or(-1)
    let exported_def_id = exported_scheme.def_id.unwrap_or(-1)
    if !shadow_producers_semantically_equal(
            ctx.env.types.ownership_metadata, some(local_def_id),
            exported, some(exported_def_id)) {
        panic("unreachable: same-origin normalized callable metadata differs")
    }
}

fn inject_module_exports(mut ctx: InferCtx, exports: List<ModuleExports>) {
    // Canonical value payloads are the only source keys consumed by the
    // resolver plan. Export display keys are intentionally not hydrated:
    // same-leaf exports from unrelated modules may coexist, while each exact
    // value/constructor origin is installed once with a checker-local DefId.
    let mut hydrated_value_origins: Set<Str> = set_new()
    let mut hydrated_method_schemes: Map<Str, TypeScheme> = map_new()
    let mut hydrated_effect_ops: Map<Str, EffectOpDef> = map_new()
    let mut hydrated_trait_methods: Map<Str, TraitMethodDef> = map_new()
    let mut hydrated_sig_schemes: Map<Str, TypeScheme> = map_new()
    for mod_ in exports {
        merge_imported_shadow_shapes(ctx, mod_.ownership_metadata)
        let mut ownership_term_remap: Map<Int, Int> = map_new()
        let mut ownership_def_id_remap: Map<Int, Int> = map_new()
        let mut exact_impl_methods: Map<Str, Map<Str, TypeScheme>> = map_new()
        let mut method_targets = mod_.impl_methods.entries()
        method_targets.sort_by(compare_by_first)
        for target_entry in method_targets {
            let (target_type, methods) = target_entry
            let origins = match mod_.method_origins.get(target_type) {
                some(value) => value,
                none => {
                    report_hydrated_method_collision(
                        ctx, target_type, "<unknown>", span_zero())
                    map_new()
                }
            }
            let mut exact_methods: Map<Str, TypeScheme> = map_new()
            let mut method_entries = methods.entries()
            method_entries.sort_by(compare_by_first)
            for method_entry in method_entries {
                let (method_name, exported_scheme) = method_entry
                let method_origin_ = match origins.get(method_name) {
                    some(value) => value,
                    none => panic(
                        "unreachable: exported method has no exact origin")
                }
                let key = impl_method_origin(
                    method_origin_.origin, method_name)
                let exact_scheme = match hydrated_method_schemes.get(key) {
                    some(existing) => {
                        assert_same_origin_shadow_callable(
                            ctx, mod_.ownership_metadata,
                            existing, exported_scheme)
                        existing
                    },
                    none => {
                        let hydrated = hydrate_exact_shadow_callable(
                            ctx, mod_.ownership_metadata,
                            exported_scheme, none, none,
                            ownership_term_remap,
                            ownership_def_id_remap)
                        hydrated_method_schemes.insert(key, hydrated)
                        hydrated
                    }
                }
                exact_methods.insert(method_name, exact_scheme)
            }
            exact_impl_methods.insert(target_type, exact_methods)
        }
        let mut sorted_values = mod_.values.entries()
        sorted_values.sort_by(compare_by_first)
        for entry in sorted_values {
            let (lookup_name, scheme) = entry
            let binding_kind = mod_.value_binding_kinds.get(lookup_name)
            let is_const_getter = match binding_kind {
                some(ValueBindingKind::ConstGetter) => true,
                _ => false
            }
            let exported_callable_view = shadow_value_callable_view(
                mod_.ownership_metadata, scheme, binding_kind)
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
                if hydrated_value_origins.contains(origin) {
                    let local_scheme = match ctx.env.lookup(origin) {
                        some(value) => value,
                        none => panic(
                            "unreachable: hydrated imported value is missing")
                    }
                    let local_callable_view = shadow_value_callable_view(
                        ctx.env.types.ownership_metadata,
                        local_scheme, binding_kind)
                    match (local_callable_view.ty,
                           exported_callable_view.ty) {
                        (Type::FnType { .. }, Type::FnType { .. }) =>
                            assert_same_origin_shadow_callable(
                                ctx, mod_.ownership_metadata,
                                local_callable_view,
                                exported_callable_view),
                        (Type::FnType { .. }, _) |
                        (_, Type::FnType { .. }) => panic(
                            "unreachable: same-origin imported value kind differs"),
                        _ => {}
                    }
                } else {
                    let hydrated_value_ty = hydrate_shadow_type(
                        ctx, mod_.ownership_metadata,
                        scheme.ty, ownership_term_remap)
                    let reused_def_id = match exported_callable_view.ty {
                        Type::FnType { .. } => match exported_callable_view.def_id {
                            some(exported_id) => ownership_def_id_remap.get(
                                exported_id),
                            none => none
                        },
                        _ => none
                    }
                    ctx.env.bind(origin, TypeScheme {
                        ..scheme, ty: hydrated_value_ty,
                        def_id: reused_def_id
                    })
                    match exported_callable_view.ty {
                        Type::FnType { .. } => {
                            let bound = ctx.env.lookup(origin).unwrap()
                            let local_def_id = bound.def_id.unwrap_or(-1)
                            let hydrated = hydrate_exact_shadow_callable(
                                ctx, mod_.ownership_metadata,
                                exported_callable_view,
                                some(local_def_id), none,
                                ownership_term_remap,
                                ownership_def_id_remap)
                            ctx.env.rebind(origin, TypeScheme {
                                ..bound,
                                ty: if is_const_getter {
                                    hydrated_value_ty
                                } else {
                                    hydrated.ty
                                },
                                def_id: hydrated.def_id
                            })
                        },
                        _ => {}
                    }
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
                    let exact_sdef = hydrate_shadow_struct_def(
                        ctx, mod_.ownership_metadata,
                        sdef, ownership_term_remap)
                    if sdef.is_extern {
                        // Dependency hydration exposes only the raw ABI source.
                        // Named/wildcard imports install visible spellings via
                        // the project namespace frame; infer_decl snapshots
                        // their raw codegen identities before frame rollback.
                        ctx.env.types.extern_structs.insert(
                            exact_sdef.name, exact_sdef)
                    } else {
                        ctx.env.types.structs.insert(
                            exact_sdef.name, exact_sdef)
                    }
                },
                TypeDef::EnumDef_(edef) => {
                    let exact_edef = hydrate_shadow_enum_def(
                        ctx, mod_.ownership_metadata,
                        edef, ownership_term_remap)
                    ctx.env.types.enums.insert(exact_edef.name, exact_edef)
                },
            }
        }
        let mut sorted_type_aliases = mod_.type_aliases.entries()
        sorted_type_aliases.sort_by(compare_by_first)
        for entry in sorted_type_aliases {
            let (_, adef) = entry
            ctx.env.types.type_aliases.insert(adef.name, TypeAliasDef {
                ..adef,
                ty: hydrate_shadow_type(
                    ctx, mod_.ownership_metadata,
                    adef.ty, ownership_term_remap)
            })
        }
        let mut sorted_effects = mod_.effects.entries()
        sorted_effects.sort_by(compare_by_first)
        for entry in sorted_effects {
            let (_, effdef) = entry
            let mut exact_ops: List<EffectOpDef> = []
            for op in effdef.ops {
                let key = "${effdef.name}::${op.name}"
                let exported_term = mod_.ownership_metadata.
                    callable_by_def_id.get(op.def_id).unwrap_or(
                        CALLABLE_UNKNOWN)
                let exported_scheme = TypeScheme {
                    ty: Type::FnType {
                        params: op.params, return_type: op.return_type,
                        effects: EMPTY_ROW,
                        ownership_term: exported_term
                    },
                    type_vars: effdef.type_param_vars,
                    bounds: [], def_id: some(op.def_id)
                }
                let exact_scheme = match hydrated_effect_ops.get(key) {
                    some(existing_op) => {
                        let existing_term = ctx.env.types.ownership_metadata.
                            callable_by_def_id.get(existing_op.def_id).unwrap_or(
                                CALLABLE_UNKNOWN)
                        let existing_scheme = TypeScheme {
                            ty: Type::FnType {
                                params: existing_op.params,
                                return_type: existing_op.return_type,
                                effects: EMPTY_ROW,
                                ownership_term: existing_term
                            },
                            type_vars: effdef.type_param_vars,
                            bounds: [], def_id: some(existing_op.def_id)
                        }
                        assert_same_origin_shadow_callable(
                            ctx, mod_.ownership_metadata,
                            existing_scheme, exported_scheme)
                        existing_scheme
                    },
                    none => hydrate_exact_shadow_callable(
                        ctx, mod_.ownership_metadata,
                        exported_scheme, none, none,
                        ownership_term_remap,
                        ownership_def_id_remap)
                }
                let exact_parts = match exact_scheme.ty {
                    Type::FnType { params, return_type, .. } =>
                        (params, return_type),
                    _ => panic("unreachable: hydrated effect op is not callable")
                }
                let exact_op = EffectOpDef {
                    ..op,
                    def_id: exact_scheme.def_id.unwrap_or(-1),
                    params: exact_parts.0,
                    return_type: exact_parts.1
                }
                hydrated_effect_ops.insert(key, exact_op)
                exact_ops.push(exact_op)
            }
            ctx.env.types.effects.insert(effdef.name, EffectDef {
                ..effdef, ops: exact_ops
            })
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
            let (_, tdef) = entry
            let mut exact_methods: List<TraitMethodDef> = []
            for method in tdef.methods {
                let key = "${tdef.name}::${method.name}"
                let exported_scheme = TypeScheme {
                    ty: method.ty, type_vars: [], bounds: [],
                    def_id: some(method.def_id)
                }
                let exact_scheme = match hydrated_trait_methods.get(key) {
                    some(existing_method) => {
                        let existing_scheme = TypeScheme {
                            ty: existing_method.ty,
                            type_vars: [], bounds: [],
                            def_id: some(existing_method.def_id)
                        }
                        assert_same_origin_shadow_callable(
                            ctx, mod_.ownership_metadata,
                            existing_scheme, exported_scheme)
                        existing_scheme
                    },
                    none => hydrate_exact_shadow_callable(
                        ctx, mod_.ownership_metadata,
                        exported_scheme, none, none,
                        ownership_term_remap,
                        ownership_def_id_remap)
                }
                let exact_method = TraitMethodDef {
                    ..method,
                    def_id: exact_scheme.def_id.unwrap_or(-1),
                    ty: exact_scheme.ty
                }
                hydrated_trait_methods.insert(key, exact_method)
                exact_methods.push(exact_method)
            }
            let mut exact_assoc_types: List<AssocTypeDef> = []
            for assoc in tdef.assoc_types {
                exact_assoc_types.push(AssocTypeDef {
                    ..assoc,
                    default_type: match assoc.default_type {
                        some(ty) => some(hydrate_shadow_type(
                            ctx, mod_.ownership_metadata,
                            ty, ownership_term_remap)),
                        none => none
                    }
                })
            }
            ctx.env.trait_reg.traits.insert(tdef.name, TraitDef {
                ..tdef, methods: exact_methods,
                assoc_types: exact_assoc_types
            })
        }
        let mut sorted_sigs = mod_.sigs.entries()
        sorted_sigs.sort_by(compare_by_first)
        for entry in sorted_sigs {
            let (_, sigdef) = entry
            // Resolver bindings consume canonical payload identities. Display
            // and leaf aliases are transactional namespace-frame overlays.
            let mut exact_members: Map<Str, TypeScheme> = map_new()
            let mut members = sigdef.members.entries()
            members.sort_by(compare_by_first)
            for member_entry in members {
                let (member_name, exported_scheme) = member_entry
                let key = "${sigdef.name}::${member_name}"
                let exact_scheme = match hydrated_sig_schemes.get(key) {
                    some(existing) => {
                        assert_same_origin_shadow_callable(
                            ctx, mod_.ownership_metadata,
                            existing, exported_scheme)
                        existing
                    },
                    none => {
                        let hydrated = hydrate_exact_shadow_callable(
                            ctx, mod_.ownership_metadata,
                            exported_scheme, none, none,
                            ownership_term_remap,
                            ownership_def_id_remap)
                        hydrated_sig_schemes.insert(key, hydrated)
                        hydrated
                    }
                }
                exact_members.insert(member_name, exact_scheme)
            }
            ctx.env.types.sigs.insert(sigdef.name, SigDef {
                ..sigdef, members: exact_members
            })
        }
        for impl_ in mod_.trait_impls {
            let mut exact_method_schemes: Map<Str, TypeScheme> = map_new()
            let mut exported_methods = impl_.method_schemes.entries()
            exported_methods.sort_by(compare_by_first)
            for method_entry in exported_methods {
                let (method_name, exported_scheme) = method_entry
                let key = impl_method_origin(impl_.origin, method_name)
                let exact_scheme = match hydrated_method_schemes.get(key) {
                    some(existing) => {
                        assert_same_origin_shadow_callable(
                            ctx, mod_.ownership_metadata,
                            existing, exported_scheme)
                        existing
                    },
                    none => {
                        let hydrated = hydrate_exact_shadow_callable(
                            ctx, mod_.ownership_metadata,
                            exported_scheme, none, none,
                            ownership_term_remap,
                            ownership_def_id_remap)
                        hydrated_method_schemes.insert(key, hydrated)
                        hydrated
                    }
                }
                exact_method_schemes.insert(method_name, exact_scheme)
            }
            let mut exact_assoc_types: Map<Str, Type> = map_new()
            let mut assoc_entries = impl_.assoc_types.entries()
            assoc_entries.sort_by(compare_by_first)
            for assoc_entry in assoc_entries {
                let (assoc_name, assoc_type) = assoc_entry
                exact_assoc_types.insert(assoc_name, hydrate_shadow_type(
                    ctx, mod_.ownership_metadata,
                    assoc_type, ownership_term_remap))
            }
            let exact_impl = ImplEntry {
                ..impl_, method_schemes: exact_method_schemes,
                assoc_types: exact_assoc_types
            }
            match find_impl(
                ctx.env.trait_reg,
                exact_impl.target_type_name,
                exact_impl.trait_name) {
                some(existing) => {
                    if existing.origin != exact_impl.origin {
                        let _ = type_error(ctx.sink, E0504,
                            "Duplicate impl '${nominal_display_name(exact_impl.trait_name)}' for '${nominal_display_name(exact_impl.target_type_name)}' from distinct dependency origins",
                            exact_impl.span, DiagnosticContext::TraitError {
                                detail: "duplicate imported target/trait implementation"
                            })
                    }
                },
                none => {}
            }
            add_impl(ctx.env.trait_reg, exact_impl)
        }
        let mut sorted_impl_methods = exact_impl_methods.entries()
        sorted_impl_methods.sort_by(compare_by_first)
        for entry in sorted_impl_methods {
            let (type_name, methods) = entry
            let exported_origins = mod_.method_origins.get(type_name)
            let mut sorted_meths = methods.entries()
            sorted_meths.sort_by(compare_by_first)
            for mentry in sorted_meths {
                let (method_name, scheme) = mentry
                match exported_origins {
                    some(origins) => match origins.get(method_name) {
                        some(origin) => {
                            let _ = install_method_scheme(
                                ctx.env.trait_reg, ctx.sink,
                                type_name, method_name, scheme, origin)
                        },
                        none => {
                            report_hydrated_method_collision(
                                ctx, type_name, method_name, span_zero())
                        }
                    },
                    none => {
                        report_hydrated_method_collision(
                            ctx, type_name, method_name, span_zero())
                    }
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
