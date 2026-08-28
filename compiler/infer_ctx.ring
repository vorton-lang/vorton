use types::{Type, Effect, EffectRow, RecordField, StructField,
    INT, FLOAT, STR, BOOL, UNIT, NEVER, ANY, EMPTY_ROW,
    type_to_string, nominal_display_name, types_equal, make_option_type, type_to_builtin_name,
    row_merge, effects_match_kind}
use ast::{Span, Pattern, TypeExpr, RecordTypeField, NamedPatternField, span_zero, EffectExpr,
    UseDecl, UseImport}
use hir::{HExpr, HStmt, HParam, ValueBindingKind,
    HCallableEffectActual, HCallableEffectInstantiation,
    HPatternBinding, HPatternPlan, HPatternFieldPlan,
    h_pattern_wildcard, h_pattern_binding, h_pattern_literal,
    h_pattern_tuple, h_pattern_struct, h_pattern_variant, h_pattern_or,
    make_h_pattern_field_plan, h_tuple_projection,
    h_nominal_projection, h_variant_projection,
    trait_dict_name, trait_bound_param_name,
    BUILTIN_INT, BUILTIN_FLOAT, BUILTIN_STR, BUILTIN_BOOL,
    BUILTIN_OPTION, BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET,
    compare_by_first}
use hir_exact::{
    DictRef, dict_ref_exact,
    make_simple_dict_ref, make_static_dict_ref, make_wrapped_dict_ref
}
use diagnostics::{DiagnosticContext, DiagnosticNote, Diagnostic, CollectingSink, Severity, Suggestion, make_diag, make_diagnostic}
use codes::{E0201, E0204, E0301, E0302, E0407, E0503, E0511, E0512, E0513, E0705, E0707}
use union_find::{UnionFind, new_union_find, uf_find}
use env::{TypeEnv, TypeScheme, SchemeBound, AssocConstraintEntry,
    EffectFactCheckpoint,
    StructDef, EnumDef, TypeAliasDef, EffectDef, EffectAliasDef, TraitDef,
    ImplEntry, ImplMethodSchemeCore, ImplAssocPredicate,
    new_type_env, mono,
    apply_subst, apply_subst_row, apply_subst_map,
    instantiate_effect_header_schema,
    define_effect_header_schema, publish_effect_header_schema,
    validate_effect_header_schema,
    project_existing_effect_header_schema,
    effect_fact_checkpoint, rollback_effect_facts,
    register_callable_effect_header,
    instantiate_type_alias_schema, find_impl, lookup_variant,
    exact_scheme_value_origin, build_scheme_var_map,
    impl_method_core_as_scheme, frozen_impl_predicates,
    impl_method_core_type, impl_method_core_type_vars,
    impl_method_core_effect_schema,
    impl_predicate_subject_type_var, impl_predicate_trait_name,
    impl_predicate_assoc_constraints, impl_assoc_predicate_name,
    impl_assoc_predicate_type, instantiate_impl_runtime_requirements,
    registered_trait_contract_owner, compiler_owned_extern_symbol}
use unify::{UnificationError, empty_subst, unify, occurs_in, unify_effect_params}
use resolver::{ResolvedNamespacePlan, ModuleFramePlan, ResolvedNamespaceBinding,
    StructIdentityFact, TraitIdentityFact, EnumVariantFactGroup,
    EffectIdentityFact,
    SourceImplProviderFact,
    DelegateProviderFact, NominalDerivedProviderPlanFact, NamespaceKind}
use ir_identity::{SymbolRef, SlotRef, PathRef, PathRole, HandledEffectRef,
    OriginRef,
    symbol_ref_canonical_payload,
    symbol_ref_origin_module_key, symbol_ref_declaration_site_path,
    symbol_ref_namespace_kind, namespace_kind_same, namespace_value,
    namespace_nominal,
    symbol_ref_same, symbol_ref_is_prelude,
    ImplProviderRef, ImplOwnerRef, ImplMethodRef,
    impl_provider_ref_same, impl_owner_ref_same,
    impl_method_ref_member,
    nominal_field_ref_same, trait_method_ref_same,
    registered_nominal_ref_same, variant_ref_same,
    variant_field_ref_same,
    handled_effect_ref_same, system_effect_console, system_effect_fs,
    system_effect_process,
    registered_nominal_ref_symbol, registered_trait_ref_symbol,
    handled_effect_ref_symbol,
    registered_trait_ref_display_name, registered_trait_ref_same,
    make_path_ref, make_synthetic_slot_ref, make_module_body_ref,
    path_owner_for_symbol, path_owner_for_module_body, path_ref_owner,
    path_ref_normalized_child_path, path_role_child,
    make_path_origin_ref, make_symbol_origin_ref,
    path_role_capture, path_role_handler,
    path_role_synthetic, path_role_declaration,
    path_role_parameter,
    slot_domain_lexical, make_source_slot_ref}
use ir_inventory::{ExecutableRef, ExactDictRef,
    make_parameter_dict_ref, make_exact_static_dict_ref,
    make_exact_wrapped_dict_ref,
    effect_operation_ref_same,
    EffectOperationRef, effect_operation_ref_member,
    make_anonymous_executable_ref, make_named_executable_ref,
    executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_anonymous_path,
    executable_ref_same,
    BinderEntry, BinderKind, make_source_binder_entry, binder_kind_let,
    binder_kind_var,
    binder_kind_for, binder_kind_destructure, binder_kind_source_param,
    HandledEvidenceRef, HandledEvidenceCapture,
    make_semantic_evidence_binder, make_handled_evidence_ref,
    make_handled_evidence_capture,
    handled_evidence_requirement, handled_evidence_binding,
    handled_evidence_contract_owner, handled_evidence_ordinal,
    handled_evidence_ref_same,
    handled_evidence_capture_requirement,
    handled_evidence_capture_source, handled_evidence_capture_target,
    binder_entry_kind, binder_kind_tag,
    binder_kind_handled_evidence_param,
    binder_kind_handled_evidence_local,
    binder_kind_handled_evidence_capture}
use effect_contract::{TypedEffectHeaderSchema,
    empty_typed_effect_header_schema,
    typed_effect_header_schema_bindings,
    typed_effect_header_binding_raw_tail,
    typed_effect_header_binding_parameter,
    effect_param_ref_same}
// ============================================================
// InferResult — return type for expression inference
// ============================================================

pub struct InferResult {
    pub hexpr: HExpr,
    pub subst: UnionFind,
    pub effects: EffectRow
}

// ============================================================
// Fn bounds entry type
// ============================================================

pub struct FnBoundsEntry {
    pub type_param_var_id: Int,
    pub trait_name: Str,
    pub type_param_name: Str,
    pub dict_ordinal: Int,
    pub assoc_constraints: List<AssocConstraintEntry>
}

pub fn fn_bound_dict_ref(
    owner: ExecutableRef, value: FnBoundsEntry
) -> DictRef {
    if value.dict_ordinal < 0 {
        panic("dictionary evidence: negative final bound ordinal")
    }
    make_simple_dict_ref(
        trait_bound_param_name(value.type_param_name, value.trait_name),
        make_parameter_dict_ref(owner, value.dict_ordinal))
}

pub fn validate_fn_bound_order(values: List<FnBoundsEntry>) {
    let mut index = 0
    while index < values.len() {
        if values.get(index).unwrap().dict_ordinal != index {
            panic("dictionary evidence: final bound order is not dense")
        }
        index = index + 1
    }
}

// Checker-only bridge between a function body's fresh associated-type
// variables and the registration-time associated types owned by its scheme.
// This never becomes part of HIR or the public function ABI.
pub struct AssocRebindEntry {
    pub check_type: Type,
    pub registration_type: Type?,
    pub owner_name: Str,
    pub trait_name: Str,
    pub assoc_name: Str
}

// Checker-only deferred trait evidence.  The callee type retains the exact
// instantiation variables owned by the declaration's UnionFind, while the
// optional output list is the same alias stored in HExpr::Call.  No pending
// obligation crosses a declaration-owner boundary.
pub enum PendingDictPurpose {
    DirectCallPublish { output_slot: List<DictRef> },
    ExternCallValidate,
    CallableValueShadow
}

pub enum PendingEvidenceSource {
    SchemeEvidenceSource(TypeScheme),
    ImplOwnerEvidenceSource {
        owner: ImplEntry,
        method_core: ImplMethodSchemeCore
    }
}

pub struct PendingDictObligation {
    pub runtime_owner: ExecutableRef,
    pub source: PendingEvidenceSource,
    pub callee_type: Type,
    pub fn_bounds: List<FnBoundsEntry>,
    pub span: Span,
    pub purpose: PendingDictPurpose
}

struct EvidenceFailure {
    trait_name: Str,
    suppress_diagnostic: Bool
}

// This tri-state is deliberately checker-private.  The public resolver below
// remains immediate and fail-closed for registration, forwarding, protocol
// prechecks, and final-zonk callable values.
enum SchemeEvidenceResolution {
    Resolved { dicts: List<DictRef>, assoc_mismatch: Bool },
    Pending { failures: List<EvidenceFailure> },
    Missing { failures: List<EvidenceFailure> }
}

enum DictEvidenceResolution {
    Resolved { dict_ref: DictRef },
    Pending,
    Missing { suppress_diagnostic: Bool }
}

// ============================================================
// CompileError (raised via fail effect, caught at declaration level)
// ============================================================

pub struct CompileError {}

// ============================================================
// InferCtx — mutable type inference context
// ============================================================

// Project namespace frames are lexical overlays on the current inference
// scope. Every mutation records the exact previous payload (or absence), so a
// nested frame can be removed without cloning the environment or disturbing
// canonical registrations made while the frame was active.
pub enum ProjectNamespaceUndo {
    Value { name: Str, previous: TypeScheme?, new_def_id: Int },
    Struct { name: Str, previous: StructDef? },
    Enum { name: Str, previous: EnumDef? },
    TypeAlias { name: Str, previous: TypeAliasDef? },
    Effect { name: Str, previous: EffectDef? },
    EffectAlias { name: Str, previous: EffectAliasDef? },
    Trait { name: Str, previous: TraitDef? },
    VariantToEnum { name: Str, previous: Str? },
    FnMutParams { name: Str, previous: List<Bool>? }
}

pub struct ProjectNamespaceFrameState {
    pub frame_index: Int,
    pub applied_bindings: Set<Str>,
    pub journal: List<ProjectNamespaceUndo>
}

pub struct InferCtx {
    pub core_module_key: Str,
    pub core_module_order: Int,
    pub executable_stack: List<ExecutableRef>,
    dictionary_evidence_owner_stack: List<ExecutableRef>,
    anonymous_child_counters: List<Int>,
    semantic_site_counters: List<Int>,
    handled_evidence_bindings_stack: List<List<HandledEvidenceRef>>,
    handled_evidence_captures_stack: List<List<HandledEvidenceCapture>>,
    handled_evidence_frames: List<List<HandledEvidenceRef>>,
    handled_evidence_frame_bases: List<Int>,
    pub env: TypeEnv,
    pub subst: UnionFind,
    pub sink: CollectingSink,
    pub type_param_scope: Map<Str, Type>,
    pub current_fn_return_type: Type?,
    pub current_fn_bounds: List<FnBoundsEntry>,
    pub fn_bounds_stack: List<List<FnBoundsEntry>>,
    pub pending_dict_obligations: List<PendingDictObligation>,
    pub loop_depth: Int,
    pub mod_path_stack: List<Str>,
    // Local binding DefId -> canonical value origin.  DefIds are lexical, so
    // a same-spelled local binding naturally shadows an imported/module alias.
    pub use_aliases: Map<Int, Str>,
    // Registration-owned binding kind.  Absence is deliberately interpreted
    // as LocalBorrow; neither a FnType nor a spelling may manufacture direct
    // callable/const-getter provenance.
    pub value_binding_kinds: Map<Int, ValueBindingKind>,
    // Resolver-issued value identity. The payload index is populated from the
    // namespace plan; registration relates each fresh lexical DefId to that
    // exact SymbolRef once. Core assembly consumes this map without reminting.
    pub value_symbols: Map<Int, SymbolRef>,
    value_symbols_by_payload: Map<Str, SymbolRef>,
    pub boxed_vars: Set<Int>,
    pub lambda_depth: Int,
    pub var_lambda_depth: Map<Int, Int>,
    pub fn_mut_params: Map<Str, List<Bool>>,
    pub file_extern_types: Set<Str>,
    // Qualified associated type scope: "T::Item" -> Type
    // Used to disambiguate when multiple type params have same-named associated types
    pub qualified_assoc_scope: Map<Str, Type>,
    // Function identity -> owner-qualified associated-type provenance captured
    // before check_fn_decl restores its transient scopes.
    pub rebind_assoc_provenance: Map<Str, List<AssocRebindEntry>>,
    // Transient checker protocol for scheduler-owned recursive callable SCCs.
    // ExecutableRef membership is exact; this state never owns a scheme/schema.
    active_recursive_callables: List<ExecutableRef>,
    closed_recursive_callables: List<ExecutableRef>,
    // B-125: whether the current module context allows unsafe blocks
    pub mod_unsafe_allowed: Bool,
    // B-002p1: types with user `impl Drop` — collected during impl checking
    pub drop_types: Set<Str>,
    // B-107 Unit3B: one installed resolver plan, pre-indexed by exact AST
    // frame site and exact frame index. These overlays never infer ownership
    // from display names or leaf spellings.
    pub project_namespace_file_key: Str?,
    pub project_namespace_root_frame: Int?,
    pub project_namespace_child_frames: Map<Str, Int>,
    pub project_namespace_bindings: Map<Int, List<ResolvedNamespaceBinding>>,
    pub project_namespace_ctor_enums: Map<Str, Str>,
    pub project_namespace_frame_stack: List<ProjectNamespaceFrameState>
    // F2-U1b registration-only structural ledger. It is installed from the
    // resolver plan, consumed exactly once, and cleared before typed HIR use.
    struct_identity_file_key: Str?,
    struct_identity_root_frame: Int?,
    struct_identity_child_frames: Map<Str, Int>,
    struct_identity_frame_stack: List<Int>,
    struct_identity_unconsumed: List<StructIdentityFact>,
    struct_identity_pending: List<StructIdentityFact>,
    trait_identity_unconsumed: List<TraitIdentityFact>,
    enum_identity_unconsumed: List<EnumVariantFactGroup>,
    effect_identity_unconsumed: List<EffectIdentityFact>,
    source_impl_provider_unconsumed: List<SourceImplProviderFact>,
    delegate_provider_unconsumed: List<DelegateProviderFact>,
    nominal_derived_provider_unconsumed:
        List<NominalDerivedProviderPlanFact>,
    // Registration-issued AST-site index for the repeated effect/main HIR
    // checks. Values are opaque owner refs; no target/name/span is replayed.
    impl_check_root_frames: Map<Str, Int>,
    impl_check_child_frames: Map<Str, Int>,
    impl_check_frame_stack: List<(Str, Int)>,
    impl_check_owners: Map<Str, ImplOwnerRef>
}

pub fn new_infer_ctx(
    sink: CollectingSink, module_key: Str, module_order: Int
) -> InferCtx {
    InferCtx {
        core_module_key: module_key,
        core_module_order: module_order,
        executable_stack: [],
        dictionary_evidence_owner_stack: [],
        anonymous_child_counters: [],
        semantic_site_counters: [],
        handled_evidence_bindings_stack: [],
        handled_evidence_captures_stack: [],
        handled_evidence_frames: [],
        handled_evidence_frame_bases: [],
        env: new_type_env(),
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
        value_symbols: map_new(),
        value_symbols_by_payload: map_new(),
        boxed_vars: set_new(),
        lambda_depth: 0,
        var_lambda_depth: map_new(),
        fn_mut_params: map_new(),
        file_extern_types: set_new(),
        qualified_assoc_scope: map_new(),
        rebind_assoc_provenance: map_new(),
        active_recursive_callables: [],
        closed_recursive_callables: [],
        mod_unsafe_allowed: false,
        drop_types: set_new(),
        project_namespace_file_key: none,
        project_namespace_root_frame: none,
        project_namespace_child_frames: map_new(),
        project_namespace_bindings: map_new(),
        project_namespace_ctor_enums: map_new(),
        project_namespace_frame_stack: [],
        struct_identity_file_key: none,
        struct_identity_root_frame: none,
        struct_identity_child_frames: map_new(),
        struct_identity_frame_stack: [],
        struct_identity_unconsumed: [],
        struct_identity_pending: [],
        trait_identity_unconsumed: [],
        enum_identity_unconsumed: [],
        effect_identity_unconsumed: [],
        source_impl_provider_unconsumed: [],
        delegate_provider_unconsumed: [],
        nominal_derived_provider_unconsumed: [],
        impl_check_root_frames: map_new(),
        impl_check_child_frames: map_new(),
        impl_check_frame_stack: [],
        impl_check_owners: map_new()
    }
}

fn recursive_callable_list_contains(
    values: List<ExecutableRef>, wanted: ExecutableRef
) -> Bool {
    for value in values {
        if executable_ref_same(value, wanted) { return true }
    }
    false
}

fn recursive_callable_group_members(
    executables: List<ExecutableRef>
) -> List<ExecutableRef> {
    let mut members: List<ExecutableRef> = []
    for executable in executables {
        if !executable_ref_is_named(executable) {
            panic("recursive callable group: member is not a named executable")
        }
        if recursive_callable_list_contains(members, executable) {
            panic("recursive callable group: duplicate executable")
        }
        members.push(executable)
    }
    if members.len() == 0 {
        panic("recursive callable group: empty group")
    }
    members
}

fn recursive_callable_groups_same(
    left: List<ExecutableRef>, right: List<ExecutableRef>
) -> Bool {
    if left.len() != right.len() { return false }
    for executable in right {
        if !recursive_callable_list_contains(left, executable) { return false }
    }
    true
}

pub fn recursive_callable_is_active(
    ctx: InferCtx, executable: ExecutableRef
) -> Bool {
    recursive_callable_list_contains(
        ctx.active_recursive_callables, executable)
}

pub fn begin_recursive_callable_group(
    mut ctx: InferCtx, executables: List<ExecutableRef>
) {
    if ctx.active_recursive_callables.len() != 0 {
        panic("recursive callable group: nested activation")
    }
    let members = recursive_callable_group_members(executables)
    for executable in members {
        if recursive_callable_list_contains(
                ctx.closed_recursive_callables, executable) {
            panic("recursive callable group: closed executable reactivated")
        }
    }
    ctx.active_recursive_callables = members
}

pub fn end_recursive_callable_group(
    mut ctx: InferCtx, executables: List<ExecutableRef>
) {
    if ctx.active_recursive_callables.len() == 0 {
        panic("recursive callable group: deactivation without activation")
    }
    let members = recursive_callable_group_members(executables)
    if !recursive_callable_groups_same(
            ctx.active_recursive_callables, members) {
        panic("recursive callable group: deactivation membership differs")
    }
    ctx.active_recursive_callables = []
}

pub fn mark_recursive_callable_group_closed(
    mut ctx: InferCtx, executables: List<ExecutableRef>
) {
    if ctx.active_recursive_callables.len() == 0 {
        panic("recursive callable group: closure without activation")
    }
    let members = recursive_callable_group_members(executables)
    if !recursive_callable_groups_same(
            ctx.active_recursive_callables, members) {
        panic("recursive callable group: closure membership differs")
    }
    // Preflight the whole group before mutating the append-only marker set.
    for executable in members {
        if recursive_callable_list_contains(
                ctx.closed_recursive_callables, executable) {
            panic("recursive callable group: executable closed twice")
        }
    }
    for executable in members {
        ctx.closed_recursive_callables.push(executable)
    }
}

pub fn recursive_callable_is_closed(
    ctx: InferCtx, executable: ExecutableRef
) -> Bool {
    recursive_callable_list_contains(ctx.closed_recursive_callables, executable)
}

pub fn recursive_effect_fact_checkpoint(
    ctx: InferCtx
) -> EffectFactCheckpoint {
    effect_fact_checkpoint(ctx.env)
}

pub fn rollback_recursive_effect_facts(
    mut ctx: InferCtx, checkpoint: EffectFactCheckpoint
) {
    rollback_effect_facts(ctx.env, checkpoint)
}

fn build_callable_effect_instantiation(
    scheme: TypeScheme, instantiated_signature: Type, subst: UnionFind
) -> HCallableEffectInstantiation {
    let mapping = build_scheme_var_map(scheme, instantiated_signature)
    let mut substitutions: List<HCallableEffectActual> = []
    let mut raw_tails: List<Int> = []
    for binding in typed_effect_header_schema_bindings(
            scheme.effect_schema) {
        let raw_tail = typed_effect_header_binding_raw_tail(binding)
        let source = typed_effect_header_binding_parameter(binding)
        if raw_tails.contains(raw_tail) {
            panic("callable effect instantiation: raw formal repeats")
        }
        for existing in substitutions {
            if effect_param_ref_same(existing.source, source) {
                panic("callable effect instantiation: source formal repeats")
            }
        }
        let mapped = match mapping.get(raw_tail) {
            some(actual) => apply_subst(subst, actual),
            none => panic(
                "callable effect instantiation: formal mapping is absent")
        }
        let actual = match mapped {
            Type::EffectRowType { effects, tail } => EffectRow {
                effects: effects, tail: tail
            },
            _ => panic(
                "callable effect instantiation: formal mapped to non-row")
        }
        raw_tails.push(raw_tail)
        substitutions.push(HCallableEffectActual {
            source: source, actual: actual
        })
    }

    HCallableEffectInstantiation { substitutions: substitutions }
}

pub fn build_scheme_callable_effect_instantiation(
    scheme: TypeScheme, instantiated_signature: Type, subst: UnionFind
) -> HCallableEffectInstantiation {
    validate_effect_header_schema(
        [scheme.ty], scheme.type_vars, scheme.effect_schema)
    build_callable_effect_instantiation(
        scheme, instantiated_signature, subst)
}

pub fn build_impl_method_callable_effect_instantiation(
    core: ImplMethodSchemeCore,
    instantiated_signature: Type, subst: UnionFind
) -> HCallableEffectInstantiation {
    build_callable_effect_instantiation(
        impl_method_core_as_scheme(core), instantiated_signature, subst)
}

// Constraint-only recursive HIR is discarded before group publication. The
// retained pass runs after end_recursive_callable_group and publishes facts.
pub fn publish_anonymous_callable_effect_header(
    mut ctx: InferCtx, executable: ExecutableRef, signature: Type
) {
    if ctx.active_recursive_callables.len() != 0 { return }
    let schema = project_existing_effect_header_schema(ctx.env, signature)
    publish_exact_callable_effect_header(ctx, executable, signature, schema)
}

fn install_monomorphic_scheme_bounds(
    mut ctx: InferCtx, scheme: TypeScheme
) {
    for bound in scheme.bounds {
        if !scheme.type_vars.contains(bound.type_var) {
            panic("recursive callable scheme: bound subject is not quantified")
        }
        let mut existing: Set<Str> = match
                ctx.env.scope.var_bounds.get(bound.type_var) {
            some(bounds) => bounds,
            none => set_new()
        }
        existing.insert(bound.trait_name)
        ctx.env.scope.var_bounds.insert(bound.type_var, existing)
    }
}

pub fn instantiate_callable_scheme(
    mut ctx: InferCtx, scheme: TypeScheme
) -> Type {
    match scheme.def_id {
        some(def_id) => match ctx.value_symbols.get(def_id) {
            some(symbol) => if recursive_callable_is_active(
                    ctx, make_named_executable_ref(symbol)) {
                install_monomorphic_scheme_bounds(ctx, scheme)
                return scheme.ty
            },
            none => {}
        },
        none => {}
    }
    ctx.env.instantiate(scheme)
}

fn install_monomorphic_impl_predicates(
    mut ctx: InferCtx, owner: ImplEntry, core: ImplMethodSchemeCore
) {
    let type_vars = impl_method_core_type_vars(core)
    for predicate in frozen_impl_predicates(owner.predicates) {
        let subject = impl_predicate_subject_type_var(predicate)
        if !type_vars.contains(subject) {
            panic("recursive impl method: predicate subject is not quantified")
        }
        let mut existing: Set<Str> = match
                ctx.env.scope.var_bounds.get(subject) {
            some(bounds) => bounds,
            none => set_new()
        }
        existing.insert(impl_predicate_trait_name(predicate))
        ctx.env.scope.var_bounds.insert(subject, existing)
    }
}

pub fn instantiate_callable_impl_method(
    mut ctx: InferCtx, owner: ImplEntry, core: ImplMethodSchemeCore,
    method_ref: ImplMethodRef
) -> Type {
    let executable = make_named_executable_ref(
        impl_method_ref_member(method_ref))
    if recursive_callable_is_active(ctx, executable) {
        install_monomorphic_impl_predicates(ctx, owner, core)
        return impl_method_core_type(core)
    }
    ctx.env.instantiate_impl_method_core(owner, core)
}

fn project_child_site_key(parent_frame_index: Int, decl_index: Int) -> Str {
    "${parent_frame_index}|${decl_index}"
}

fn project_binding_key(binding: ResolvedNamespaceBinding) -> Str {
    let namespace = match binding.namespace {
        NamespaceKind::Value => "value",
        NamespaceKind::Struct => "struct",
        NamespaceKind::Enum => "enum",
        NamespaceKind::TypeAlias => "type-alias",
        NamespaceKind::Effect => "effect",
        NamespaceKind::EffectAlias => "effect-alias",
        NamespaceKind::Trait => "trait"
    }
    // This is only an application bucket for one already-resolved target
    // frame.  Resolver SymbolRef remains the sole origin authority.
    "${namespace}|${binding.exposed_name}"
}

fn current_scope_value(ctx: InferCtx, name: Str) -> TypeScheme? {
    if ctx.env.scope.scopes.len() == 0 { return none }
    let index = ctx.env.scope.scopes.len() - 1
    match ctx.env.scope.scopes.get(index) {
        some(scope) => scope.variables.get(name),
        none => none
    }
}

fn set_current_scope_value(mut ctx: InferCtx, name: Str, scheme: TypeScheme) {
    let index = ctx.env.scope.scopes.len() - 1
    match ctx.env.scope.scopes.get(index) {
        some(scope) => { scope.variables.insert(name, scheme) },
        none => panic("unreachable: project namespace frame without inference scope")
    }
}

fn remove_current_scope_value(mut ctx: InferCtx, name: Str) {
    let index = ctx.env.scope.scopes.len() - 1
    match ctx.env.scope.scopes.get(index) {
        some(scope) => { scope.variables.remove(name) },
        none => {}
    }
}

fn apply_project_value_binding(
    mut ctx: InferCtx,
    binding: ResolvedNamespaceBinding,
    mut state: ProjectNamespaceFrameState
) -> Bool {
    let canonical_payload =
        symbol_ref_canonical_payload(binding.symbol)
    match ctx.env.lookup(canonical_payload) {
        none => false,
        some(source_scheme) => {
            let previous = current_scope_value(ctx, binding.exposed_name)
            let new_def_id = ctx.env.fresh_def_id()
            state.journal.push(ProjectNamespaceUndo::Value {
                name: binding.exposed_name,
                previous: previous,
                new_def_id: new_def_id
            })
            set_current_scope_value(ctx, binding.exposed_name, TypeScheme {
                ty: source_scheme.ty,
                type_vars: source_scheme.type_vars,
                bounds: source_scheme.bounds,
                effect_schema: source_scheme.effect_schema,
                def_id: some(new_def_id)
            })

            let ultimate = exact_scheme_value_origin(
                ctx.use_aliases, source_scheme, canonical_payload)
            ctx.use_aliases.insert(new_def_id, ultimate)
            ctx.value_binding_kinds.insert(
                new_def_id, value_binding_kind(ctx, source_scheme.def_id))
            // The resolver binding already owns the exact value identity.
            // Relate the fresh lexical DefId directly; constructors must not
            // recover this fact from their legacy codegen spelling.
            ctx.value_symbols.insert(new_def_id, binding.symbol)
            match variant_ctor_origin(ctx, source_scheme) {
                some(origin) => {
                    ctx.env.types.variant_ctor_origins.insert(new_def_id, origin)
                },
                none => {}
            }

            // Spelling-keyed metadata is part of the lexical overlay too.
            // Absence on the canonical source removes any parent-frame entry,
            // preventing stale metadata from leaking through shadowing.
            let previous_variant = ctx.env.types.variant_to_enum.get(
                binding.exposed_name)
            state.journal.push(ProjectNamespaceUndo::VariantToEnum {
                name: binding.exposed_name,
                previous: previous_variant
            })
            match ctx.project_namespace_ctor_enums.get(canonical_payload) {
                some(enum_payload) => {
                    ctx.env.types.variant_to_enum.insert(
                        binding.exposed_name, enum_payload)
                },
                none => { ctx.env.types.variant_to_enum.remove(binding.exposed_name) }
            }

            let previous_mut = ctx.fn_mut_params.get(binding.exposed_name)
            state.journal.push(ProjectNamespaceUndo::FnMutParams {
                name: binding.exposed_name,
                previous: previous_mut
            })
            let source_mut = match ctx.fn_mut_params.get(canonical_payload) {
                some(flags) => some(flags),
                none => ctx.fn_mut_params.get(ultimate)
            }
            match source_mut {
                some(flags) => { ctx.fn_mut_params.insert(binding.exposed_name, flags) },
                none => { ctx.fn_mut_params.remove(binding.exposed_name) }
            }
            true
        }
    }
}

fn apply_project_namespace_binding(
    mut ctx: InferCtx,
    binding: ResolvedNamespaceBinding,
    mut state: ProjectNamespaceFrameState
) -> Bool {
    let canonical_payload =
        symbol_ref_canonical_payload(binding.symbol)
    match binding.namespace {
        NamespaceKind::Value => apply_project_value_binding(ctx, binding, state),
        NamespaceKind::Struct => {
            let source = match ctx.env.types.extern_structs.get(canonical_payload) {
                some(def) => some(def),
                none => ctx.env.types.structs.get(canonical_payload)
            }
            match source {
                none => false,
                some(def) => {
                    if !symbol_ref_same(
                            binding.symbol,
                            registered_nominal_ref_symbol(def.owner_ref)) {
                        panic("project hydration: struct owner identity mismatch")
                    }
                    state.journal.push(ProjectNamespaceUndo::Struct {
                        name: binding.exposed_name,
                        previous: ctx.env.types.structs.get(binding.exposed_name)
                    })
                    ctx.env.types.structs.insert(binding.exposed_name, def)
                    true
                }
            }
        },
        NamespaceKind::Enum => match ctx.env.types.enums.get(canonical_payload) {
            none => false,
            some(def) => {
                if !symbol_ref_same(
                        binding.symbol,
                        registered_nominal_ref_symbol(def.owner_ref)) {
                    panic("project hydration: enum owner identity mismatch")
                }
                state.journal.push(ProjectNamespaceUndo::Enum {
                    name: binding.exposed_name,
                    previous: ctx.env.types.enums.get(binding.exposed_name)
                })
                ctx.env.types.enums.insert(binding.exposed_name, def)
                true
            }
        },
        NamespaceKind::TypeAlias => match ctx.env.types.type_aliases.get(canonical_payload) {
            none => false,
            some(def) => {
                if !symbol_ref_same(binding.symbol, def.owner_ref) {
                    panic("project hydration: type alias owner identity mismatch")
                }
                state.journal.push(ProjectNamespaceUndo::TypeAlias {
                    name: binding.exposed_name,
                    previous: ctx.env.types.type_aliases.get(binding.exposed_name)
                })
                ctx.env.types.type_aliases.insert(binding.exposed_name, def)
                true
            }
        },
        NamespaceKind::Effect => match ctx.env.types.effects.get(canonical_payload) {
            none => false,
            some(def) => {
                match def.owner_ref {
                    some(owner) => if !symbol_ref_same(
                            binding.symbol, owner) ||
                            def.handled_ref.is_none() {
                        panic("project hydration: effect owner identity mismatch")
                    },
                    none => panic(
                        "project hydration: source effect has no exact owner")
                }
                state.journal.push(ProjectNamespaceUndo::Effect {
                    name: binding.exposed_name,
                    previous: ctx.env.types.effects.get(binding.exposed_name)
                })
                ctx.env.types.effects.insert(binding.exposed_name, def)
                true
            }
        },
        NamespaceKind::EffectAlias => match ctx.env.types.effect_aliases.get(canonical_payload) {
            none => false,
            some(def) => {
                state.journal.push(ProjectNamespaceUndo::EffectAlias {
                    name: binding.exposed_name,
                    previous: ctx.env.types.effect_aliases.get(binding.exposed_name)
                })
                ctx.env.types.effect_aliases.insert(binding.exposed_name, def)
                true
            }
        },
        NamespaceKind::Trait => match ctx.env.trait_reg.traits.get(canonical_payload) {
            none => false,
            some(def) => {
                if !symbol_ref_same(
                        binding.symbol,
                        registered_trait_ref_symbol(def.owner_ref)) ||
                   registered_trait_ref_display_name(def.owner_ref) !=
                        def.name || def.name != canonical_payload ||
                   !registered_trait_ref_same(
                        registered_trait_contract_owner(def.contract),
                        def.owner_ref) {
                    panic("project hydration: trait owner identity mismatch")
                }
                state.journal.push(ProjectNamespaceUndo::Trait {
                    name: binding.exposed_name,
                    previous: ctx.env.trait_reg.traits.get(binding.exposed_name)
                })
                ctx.env.trait_reg.traits.insert(binding.exposed_name, def)
                true
            }
        }
    }
}

fn restore_project_namespace_undo(mut ctx: InferCtx, undo: ProjectNamespaceUndo) {
    match undo {
        ProjectNamespaceUndo::Value { name, previous, new_def_id } => {
            match previous {
                some(scheme) => set_current_scope_value(ctx, name, scheme),
                none => remove_current_scope_value(ctx, name)
            }
            ctx.use_aliases.remove(new_def_id)
            ctx.value_binding_kinds.remove(new_def_id)
            ctx.env.types.variant_ctor_origins.remove(new_def_id)
        },
        ProjectNamespaceUndo::Struct { name, previous } => match previous {
            some(def) => { ctx.env.types.structs.insert(name, def) },
            none => { ctx.env.types.structs.remove(name) }
        },
        ProjectNamespaceUndo::Enum { name, previous } => match previous {
            some(def) => { ctx.env.types.enums.insert(name, def) },
            none => { ctx.env.types.enums.remove(name) }
        },
        ProjectNamespaceUndo::TypeAlias { name, previous } => match previous {
            some(def) => { ctx.env.types.type_aliases.insert(name, def) },
            none => { ctx.env.types.type_aliases.remove(name) }
        },
        ProjectNamespaceUndo::Effect { name, previous } => match previous {
            some(def) => { ctx.env.types.effects.insert(name, def) },
            none => { ctx.env.types.effects.remove(name) }
        },
        ProjectNamespaceUndo::EffectAlias { name, previous } => match previous {
            some(def) => { ctx.env.types.effect_aliases.insert(name, def) },
            none => { ctx.env.types.effect_aliases.remove(name) }
        },
        ProjectNamespaceUndo::Trait { name, previous } => match previous {
            some(def) => { ctx.env.trait_reg.traits.insert(name, def) },
            none => { ctx.env.trait_reg.traits.remove(name) }
        },
        ProjectNamespaceUndo::VariantToEnum { name, previous } => match previous {
            some(enum_name) => { ctx.env.types.variant_to_enum.insert(name, enum_name) },
            none => { ctx.env.types.variant_to_enum.remove(name) }
        },
        ProjectNamespaceUndo::FnMutParams { name, previous } => match previous {
            some(flags) => { ctx.fn_mut_params.insert(name, flags) },
            none => { ctx.fn_mut_params.remove(name) }
        }
    }
}

// Install the one-file view of the portable project plan. The frame tree is
// indexed by exact `(parent_frame, decl_index)` sites; no owner or leaf key is
// used for child-frame recovery.
pub fn install_project_namespace_plan(
    mut ctx: InferCtx, file_key: Str, plan: ResolvedNamespacePlan
) -> Bool {
    ctx.project_namespace_file_key = some(file_key)
    ctx.project_namespace_root_frame = none
    ctx.project_namespace_child_frames = map_new()
    ctx.project_namespace_bindings = map_new()
    ctx.project_namespace_ctor_enums = map_new()
    ctx.project_namespace_frame_stack = []

    for frame in plan.frames {
        if frame.file_key == file_key {
            if frame.parent_frame_index < 0 {
                ctx.project_namespace_root_frame = some(frame.frame_index)
            } else {
                ctx.project_namespace_child_frames.insert(
                    project_child_site_key(
                        frame.parent_frame_index, frame.decl_index),
                    frame.frame_index)
            }
        }
    }
    for binding in plan.bindings {
        if binding.file_key == file_key {
            match ctx.project_namespace_bindings.get(binding.frame_index) {
                some(existing) => existing.push(binding),
                none => {
                    ctx.project_namespace_bindings.insert(
                        binding.frame_index, [binding])
                }
            }
        }
    }
    for group in plan.enum_variant_facts {
        let enum_payload =
            symbol_ref_canonical_payload(group.enum_symbol)
        for ctor in group.constructors {
            let ctor_payload =
                symbol_ref_canonical_payload(ctor.symbol)
            ctx.project_namespace_ctor_enums.insert(
                ctor_payload, enum_payload)
        }
    }
    ctx.project_namespace_root_frame.is_some()
}

pub fn enter_project_root_frame(mut ctx: InferCtx) -> Bool {
    match ctx.project_namespace_root_frame {
        none => false,
        some(frame_index) => {
            ctx.project_namespace_frame_stack.push(ProjectNamespaceFrameState {
                frame_index: frame_index,
                applied_bindings: set_new(),
                journal: []
            })
            refresh_project_namespace_frame(ctx)
            true
        }
    }
}

pub fn enter_project_child_frame(mut ctx: InferCtx, decl_index: Int) -> Bool {
    if ctx.project_namespace_frame_stack.len() == 0 { return false }
    let parent_stack_index = ctx.project_namespace_frame_stack.len() - 1
    let parent_frame_index = match ctx.project_namespace_frame_stack.get(
        parent_stack_index) {
        some(state) => state.frame_index,
        none => return false
    }
    match ctx.project_namespace_child_frames.get(
        project_child_site_key(parent_frame_index, decl_index)) {
        none => false,
        some(frame_index) => {
            ctx.project_namespace_frame_stack.push(ProjectNamespaceFrameState {
                frame_index: frame_index,
                applied_bindings: set_new(),
                journal: []
            })
            refresh_project_namespace_frame(ctx)
            true
        }
    }
}

pub fn refresh_project_namespace_frame(mut ctx: InferCtx) {
    if ctx.project_namespace_frame_stack.len() == 0 { return }
    let state_index = ctx.project_namespace_frame_stack.len() - 1
    match ctx.project_namespace_frame_stack.get(state_index) {
        none => {},
        some(state) => match ctx.project_namespace_bindings.get(state.frame_index) {
            none => {},
            some(bindings) => {
                for binding in bindings {
                    let key = project_binding_key(binding)
                    if !state.applied_bindings.contains(key) {
                        if apply_project_namespace_binding(ctx, binding, state) {
                            // A binding becomes applied only after its exact
                            // canonical payload was found and installed.
                            state.applied_bindings.insert(key)
                        }
                    }
                }
            }
        }
    }
}

pub fn exit_project_namespace_frame(mut ctx: InferCtx) -> Bool {
    if ctx.project_namespace_frame_stack.len() == 0 { return false }
    let mut state = ctx.project_namespace_frame_stack.pop().unwrap()
    while state.journal.len() > 0 {
        match state.journal.pop() {
            some(undo) => restore_project_namespace_undo(ctx, undo),
            none => {}
        }
    }
    true
}

// ============================================================
// Error helper
// ============================================================

fn infer_suggestion(code: Str, message: Str, context: DiagnosticContext) -> List<Suggestion> {
    let mut suggestions: List<Suggestion> = []

    // Type mismatch suggestions
    if code == "E0301" {
        if message.contains("Str") && message.contains("Int") {
            suggestions.push(Suggestion {
                message: "Use parse_int() to convert Str to Int, or .to_str() for Int to Str",
                replacement: none,
                span: none
            })
        }
        if message.contains("Str") && message.contains("Float") {
            suggestions.push(Suggestion {
                message: "Use parse_float() to convert Str to Float, or .to_str() for Float to Str",
                replacement: none,
                span: none
            })
        }
        if message.contains("Option") {
            suggestions.push(Suggestion {
                message: "Use match, .unwrap_or(), or .unwrap_or_else() to handle Option values",
                replacement: none,
                span: none
            })
        }
        if message.contains("Bool") && (message.contains("Int") || message.contains("Str")) {
            suggestions.push(Suggestion {
                message: "Bool cannot be implicitly converted; use an if expression instead",
                replacement: none,
                span: none
            })
        }
        // Row poly field missing — suggest which field is needed
        if message.contains("missing field") {
            suggestions.push(Suggestion {
                message: "The function requires a struct with specific fields; check the field access in the function body",
                replacement: none,
                span: none
            })
        }
        // Empty collection type inference — suggest type annotation
        match context {
            TypeMismatch { expected, actual, .. } => {
                if has_unresolved_collection_type(expected) || has_unresolved_collection_type(actual) {
                    suggestions.push(Suggestion {
                        message: "Empty collection needs a type annotation, e.g.: let xs: List<Int> = []",
                        replacement: some(": List<Type>"),
                        span: none
                    })
                }
            },
            _ => {}
        }
    }

    // Numeric type required (E0303) — string concatenation attempt
    if code == "E0303" {
        if message.contains("Str") {
            suggestions.push(Suggestion {
                message: "Strings cannot use + for concatenation; use string interpolation or List<Str>.join()",
                replacement: none,
                span: none
            })
        }
    }

    // Undefined variable suggestions
    if code == "E0201" {
        match context {
            UndefinedVariable { name, scope_locals } => {
                match scope_locals {
                    some(locals) => {
                        let similar = find_similar_name(name, locals)
                        match similar {
                            some(suggestion) => {
                                suggestions.push(Suggestion {
                                    message: "Did you mean '${suggestion}'?",
                                    replacement: some(suggestion),
                                    span: none
                                })
                            },
                            none => {}
                        }
                    },
                    none => {}
                }
            },
            _ => {}
        }
    }

    // Missing field suggestions
    if code == "E0203" {
        match context {
            MissingField { field, available, .. } => {
                match available {
                    some(avail) => {
                        let similar = find_similar_name(field, avail)
                        match similar {
                            some(suggestion) => {
                                suggestions.push(Suggestion {
                                    message: "Did you mean '${suggestion}'?",
                                    replacement: some(suggestion),
                                    span: none
                                })
                            },
                            none => {}
                        }
                    },
                    none => {}
                }
            },
            _ => {}
        }
    }

    // Undefined method
    if code == "E0305" {
        suggestions.push(Suggestion {
            message: "Check available methods using the type's impl block or trait implementations",
            replacement: none,
            span: none
        })
    }

    // Immutable assignment
    if code == "E0205" {
        suggestions.push(Suggestion {
            message: "Declare the variable with 'let mut' instead of 'let' to allow reassignment",
            replacement: some("let mut"),
            span: none
        })
    }

    // Non-exhaustive pattern match
    if code == "E0601" {
        suggestions.push(Suggestion {
            message: "Add a wildcard pattern '_ => ...' or cover all missing variants",
            replacement: none,
            span: none
        })
    }

    // Unhandled effect — suggest handler
    if code == "E0403" {
        match context {
            EffectUnhandled { eff, .. } => {
                suggestions.push(Suggestion {
                    message: "Handle the '${eff}' effect using 'handle expr with { ${eff} { ... } }' or wrap in a function with 'with {${eff}}' annotation",
                    replacement: some("handle <expr> with { ${eff} { op(args) => result } }"),
                    span: none
                })
            },
            _ => {}
        }
    }

    // Effect mismatch — suggest handler when effects leak into pure context
    if code == "E0301" || code == "E0302" {
        if message.contains("effect mismatch") && message.contains("not allowed in pure context") {
            // Extract the effect names from the message for a concrete suggestion
            if message.contains("fail") {
                suggestions.push(Suggestion {
                    message: "Use 'catch { err => <handler> }' to handle the fail effect",
                    replacement: some("catch { err => <handler> }"),
                    span: none
                })
            } else {
                suggestions.push(Suggestion {
                    message: "Use 'handle ... with { ... }' for custom effects, or 'catch { ... }' for fail effects",
                    replacement: none,
                    span: none
                })
            }
        }
    }

    suggestions
}

// Check if a type string representation contains an unresolved type variable
// inside a collection type (e.g. "List<?0>", "Map<?1, ?2>", "Set<?3>")
fn has_unresolved_collection_type(type_str: Str) -> Bool {
    // Type variables in Ring are rendered as "?N" (e.g. "?0", "?1")
    // Check for patterns like "List<?" or "Map<?" or "Set<?"
    if type_str.contains("List<?") { return true }
    if type_str.contains("Map<?") { return true }
    if type_str.contains("Set<?") { return true }
    false
}

fn find_similar_name(target: Str, candidates: List<Str>) -> Str? {
    // Simple similarity: find a candidate that starts with the same first 2 chars,
    // or where one is a prefix of the other, or they differ by only 1-2 characters in length
    let mut best: Str? = none
    let mut best_score = 0

    for candidate in candidates {
        let mut score = 0
        // Exact prefix match (one is prefix of the other)
        if candidate.starts_with(target) || target.starts_with(candidate) {
            score = 3
        }
        // Same first 2 characters and similar length
        if target.len() >= 2 && candidate.len() >= 2 {
            if target.slice(0, 2) == candidate.slice(0, 2) {
                let len_diff = if target.len() > candidate.len() { target.len() - candidate.len() } else { candidate.len() - target.len() }
                if len_diff <= 2 { score = 2 }
            }
        }
        // Same length and similar starting character
        if target.len() == candidate.len() && target.len() >= 1 {
            if target.slice(0, 1) == candidate.slice(0, 1) {
                score = 1
            }
        }
        if score > best_score {
            best_score = score
            best = some(candidate)
        }
    }
    best
}

pub fn type_error(mut sink: CollectingSink, code: Str, message: Str, span: Span, context: DiagnosticContext) -> Type {
    let mut diag = make_diag(code, Severity::SevError, message, span, context)
    let suggestions = infer_suggestion(code, message, context)
    if suggestions.len() > 0 {
        diag = Diagnostic { ..diag, suggestions: suggestions }
    }
    sink.report(diag)
    Type::ErrorType
}

pub fn type_error_with_notes(mut sink: CollectingSink, code: Str, message: Str, span: Span, context: DiagnosticContext, notes: List<DiagnosticNote>) -> Type {
    let mut diag = make_diagnostic(code, Severity::SevError, message, span, context, notes)
    let suggestions = infer_suggestion(code, message, context)
    if suggestions.len() > 0 {
        diag = Diagnostic { ..diag, suggestions: suggestions }
    }
    sink.report(diag)
    Type::ErrorType
}

// ============================================================
// Unification / effect helpers
// ============================================================

pub fn merge_effects(
    sink: CollectingSink, env: TypeEnv,
    a: EffectRow, b: EffectRow, s: UnionFind, span: Span
) -> (EffectRow, UnionFind) {
    // Apply substitution to resolve already-bound tail variables before merging
    let resolved_a = apply_subst_row(s, a)
    let resolved_b = apply_subst_row(s, b)
    let mut result_s = s

    // #258/#266 contract, scoped by #265: custom effect labels denote one
    // lexical evidence value per canonical name, and Ring's single-fail-effect
    // design denotes one fail payload per row. Their type parameters therefore
    // form hard agreement contracts before row_merge deduplicates by kind.
    // Concatenating A then B and visiting each unordered occurrence pair once
    // covers A internally, B internally, and A x B without duplicate checks.
    // mut<T> stays outside this contract: it is a multi-instance marker
    // (mut<Int> and mut<Str> legitimately coexist in one row, and a bare
    // `with {mut}` instantiation is a fresh instance, not a shared one).
    // Unbound row tails are deliberately absent and remain unconstrained.
    let mut explicit_effects: List<Effect> = []
    for eff_a in resolved_a.effects { explicit_effects.push(eff_a) }
    for eff_b in resolved_b.effects { explicit_effects.push(eff_b) }
    let mut left_index = 0
    while left_index < explicit_effects.len() {
        let mut right_index = left_index + 1
        while right_index < explicit_effects.len() {
            match (explicit_effects.get(left_index), explicit_effects.get(right_index)) {
                (some(eff_left), some(eff_right)) => {
                    let has_hard_param_contract = match (eff_left, eff_right) {
                        (Effect::CustomEffect { .. }, Effect::CustomEffect { .. }) => true,
                        (Effect::FailEffect { .. }, Effect::FailEffect { .. }) => true,
                        _ => false
                    }
                    if has_hard_param_contract && effects_match_kind(eff_left, eff_right) {
                        result_s = unify_effect_params(eff_left, eff_right, result_s, env) catch {
                            e => {
                                let code = if e.is_occurs_check { E0302 } else { E0301 }
                                let _ = type_error(sink, code, e.message, span, DiagnosticContext::TypeMismatch {
                                    expected: type_to_string(Type::EffectRowType { effects: [eff_left], tail: none }),
                                    actual: type_to_string(Type::EffectRowType { effects: [eff_right], tail: none }),
                                    expression: none
                                })
                                result_s
                            }
                        }
                    }
                },
                _ => {}
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }

    // The multi-instance mut kind keeps the pre-#258 best-effort merge:
    // bind a still-free parameter variable so row_merge's kind-based dedup
    // does not lose a concrete instance, but let incompatible instances stay
    // separate row entries instead of reporting a conflict.
    for eff_b in resolved_b.effects {
        match eff_b {
            Effect::CustomEffect { .. } => { continue },
            Effect::FailEffect { .. } => { continue },
            _ => {}
        }
        for eff_a in resolved_a.effects {
            if effects_match_kind(eff_a, eff_b) {
                result_s = (unify_effect_params(eff_a, eff_b, result_s, env)) catch { _ => result_s }
                break
            }
        }
    }

    // Only deduplicate labels after all explicit parameter contracts have been
    // checked. In particular, do not let name-based row merging hide conflicts.
    let m = row_merge(resolved_a, resolved_b)

    match m.tails_to_unify {
        some(pair) => {
            let (ta, tb) = pair
            result_s = unify_at(
                sink, env,
                Type::TypeVar { id: ta, name: none },
                Type::TypeVar { id: tb, name: none },
                result_s, span
            )
        },
        none => {}
    }
    let out = (m.row, result_s)
    out
}

pub fn unify_at(sink: CollectingSink, env: TypeEnv, t1: Type, t2: Type, s: UnionFind, span: Span) -> UnionFind {
    unify(t1, t2, s, env) catch {
        e => {
            let code = if e.is_occurs_check { E0302 } else { E0301 }
            let _ = type_error(sink, code, e.message, span, DiagnosticContext::TypeMismatch {
                expected: type_to_string(apply_subst(s, t1)),
                actual: type_to_string(apply_subst(s, t2)),
                expression: none
            })
            s
        }
    }
}

pub fn unify_at_noted(sink: CollectingSink, env: TypeEnv, t1: Type, t2: Type, s: UnionFind, span: Span, notes: List<DiagnosticNote>) -> UnionFind {
    unify(t1, t2, s, env) catch {
        e => {
            let code = if e.is_occurs_check { E0302 } else { E0301 }
            let _ = type_error_with_notes(sink, code, e.message, span, DiagnosticContext::TypeMismatch {
                expected: type_to_string(apply_subst(s, t1)),
                actual: type_to_string(apply_subst(s, t2)),
                expression: none
            }, notes)
            s
        }
    }
}

// ============================================================
// Free type variable collection
// ============================================================

pub fn free_type_vars(t: Type, subst: UnionFind) -> Set<Int> {
    let resolved = apply_subst(subst, t)
    let mut result: Set<Int> = set_new()
    collect_free_vars(resolved, result)
    result
}

pub fn collect_free_vars(t: Type, mut result: Set<Int>) {
    match t {
        Type::IntType => {},
        Type::FloatType => {},
        Type::StrType => {},
        Type::BoolType => {},
        Type::UnitType => {},
        Type::NeverType => {},
        Type::AnyType => {},
        Type::ErrorType => {},
        Type::TypeVar { id, .. } => { result.insert(id) },
        Type::FnType { params, return_type, effects } => {
            for p in params { collect_free_vars(p, result) }
            collect_free_vars(return_type, result)
            match effects.tail {
                some(tail_id) => { result.insert(tail_id) },
                none => {}
            }
            for e in effects.effects {
                match e {
                    Effect::FailEffect { error_type } => collect_free_vars(error_type, result),
                    Effect::MutEffect { state_type } => collect_free_vars(state_type, result),
                    Effect::CustomEffect { type_args, .. } => {
                        for a in type_args { collect_free_vars(a, result) }
                    },
                    _ => {}
                }
            }
        },
        Type::StructType { type_params, .. } => {
            for tp in type_params { collect_free_vars(tp, result) }
        },
        Type::EnumType { type_params, .. } => {
            for tp in type_params { collect_free_vars(tp, result) }
        },
        Type::GenericType { base, args } => {
            collect_free_vars(base, result)
            for a in args { collect_free_vars(a, result) }
        },
        Type::RecordType { fields, tail, .. } => {
            for f in fields { collect_free_vars(f.ty, result) }
            match tail { some(t_id) => { result.insert(t_id) }, none => {} }
        },
        Type::TupleType { elements } => {
            for e in elements { collect_free_vars(e, result) }
        },
        Type::PtrType { pointee } => {
            collect_free_vars(pointee, result)
        },
        Type::EffectRowType { effects, tail } => {
            match tail { some(t_id) => { result.insert(t_id) }, none => {} }
            for e in effects {
                match e {
                    Effect::FailEffect { error_type } => collect_free_vars(error_type, result),
                    Effect::MutEffect { state_type } => collect_free_vars(state_type, result),
                    Effect::CustomEffect { type_args, .. } => {
                        for a in type_args { collect_free_vars(a, result) }
                    },
                    _ => {}
                }
            }
        }
    }
}

pub fn free_type_vars_in_env(env: TypeEnv, subst: UnionFind) -> Set<Int> {
    let mut result: Set<Int> = set_new()
    for scope in env.scope.scopes {
        let mut sorted_vars = scope.variables.entries()
        sorted_vars.sort_by(compare_by_first)
        for entry in sorted_vars {
            let (_, scheme) = entry
            let ftv = free_type_vars(scheme.ty, subst)
            let mut quantified: Set<Int> = set_new()
            for v in scheme.type_vars {
                let resolved = apply_subst(subst, Type::TypeVar { id: v, name: none })
                match resolved {
                    Type::TypeVar { id, .. } => { quantified.insert(id) },
                    _ => { quantified.insert(v) }
                }
            }
            for v in ftv {
                if !quantified.contains(v) { result.insert(v) }
            }
        }
    }
    result
}

// ============================================================
// Generalization
// ============================================================

pub fn generalize(env: TypeEnv, t: Type, subst: UnionFind) -> TypeScheme {
    let resolved = apply_subst(subst, t)
    let ftv_type = free_type_vars(resolved, empty_subst())
    let ftv_env = free_type_vars_in_env(env, subst)
    let mut type_vars: List<Int> = []
    let mut sorted_ftv: List<Int> = []
    for v in ftv_type { sorted_ftv.push(v) }
    sorted_ftv.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
    for v in sorted_ftv {
        if !ftv_env.contains(v) { type_vars.push(v) }
    }
    let mut bounds: List<SchemeBound> = []
    for tv in type_vars {
        match env.scope.var_bounds.get(tv) {
            some(traits) => {
                let mut sorted_traits: List<Str> = []
                for t in traits { sorted_traits.push(t) }
                sorted_traits.sort()
                for trait_name in sorted_traits {
                    bounds.push(SchemeBound { type_var: tv, trait_name: trait_name, assoc_constraints: [] })
                }
            },
            none => {}
        }
    }
    TypeScheme { ty: resolved, type_vars: type_vars, bounds: bounds,
        effect_schema: empty_typed_effect_header_schema(), def_id: none }
}

// ============================================================
// Fn effects update
// ============================================================

pub fn update_fn_effects(mut env: TypeEnv, name: Str, effects: EffectRow) {
    match env.lookup(name) {
        some(scheme) => match scheme.ty {
            Type::FnType { params, return_type, .. } => {
                let new_type = Type::FnType { params: params, return_type: return_type, effects: effects }
                env.rebind(name, TypeScheme { ..scheme, ty: new_type })
            },
            _ => {}
        },
        none => {}
    }
}

// ============================================================
// Scheme var map + dict resolution
// ============================================================

pub fn record_value_origin(mut ctx: InferCtx, local_name: Str, origin: Str) {
    match ctx.env.lookup(local_name) {
        some(scheme) => match scheme.def_id {
            some(def_id) => { ctx.use_aliases.insert(def_id, origin) },
            none => {}
        },
        none => {}
    }
}

// Constructor identity must follow the binding, not its spelling: enum
// variants may be imported or aliased, while a local with the same name must
// remain an ordinary value. The map covers fieldless and positional-payload
// constructors; named-field construction has its own HIR node.
pub fn record_variant_ctor_origin(mut ctx: InferCtx, local_name: Str, origin: Str) {
    match ctx.env.lookup(local_name) {
        some(scheme) => match scheme.def_id {
            some(def_id) => {
                ctx.env.types.variant_ctor_origins.insert(def_id, origin)
            },
            none => {}
        },
        none => {}
    }
}

pub fn variant_ctor_origin(ctx: InferCtx, scheme: TypeScheme) -> Str? {
    match scheme.def_id {
        some(def_id) => ctx.env.types.variant_ctor_origins.get(def_id),
        none => none
    }
}

pub fn has_variant_ctor_origin_def_id(ctx: InferCtx, def_id: Int) -> Bool {
    ctx.env.types.variant_ctor_origins.contains_key(def_id)
}

fn resolve_fn_bound_dict_ref(
    runtime_owner: ExecutableRef, current_fn_bounds: List<FnBoundsEntry>,
    id: Int, s: UnionFind, trait_name: Str
) -> DictRef? {
    let matching = current_fn_bounds.find(fn(fb) {
        if fb.trait_name != trait_name { false } else {
            let resolved_fb = apply_subst(s, Type::TypeVar {
                id: fb.type_param_var_id,
                name: none
            })
            let resolved_match = match resolved_fb {
                Type::TypeVar { id: resolved_id, .. } => resolved_id == id,
                _ => false
            }
            fb.type_param_var_id == id ||
                uf_find(s, fb.type_param_var_id) == id ||
                resolved_match
        }
    })
    match matching {
        some(fb) => some(fn_bound_dict_ref(runtime_owner, fb)),
        none => none
    }
}

pub fn record_value_binding_kind(mut ctx: InferCtx, local_name: Str, kind: ValueBindingKind) {
    match ctx.env.lookup(local_name) {
        some(scheme) => match scheme.def_id {
            some(def_id) => {
                ctx.value_binding_kinds.insert(def_id, kind)
                let payload = match ctx.use_aliases.get(def_id) {
                    some(origin) => origin,
                    none => local_name
                }
                match ctx.value_symbols_by_payload.get(payload) {
                    some(symbol) => {
                        match ctx.value_symbols.get(def_id) {
                            some(existing) => if !symbol_ref_same(
                                    existing, symbol) {
                                panic("value identity: DefId was rebound to another SymbolRef")
                            },
                            none => ctx.value_symbols.insert(def_id, symbol)
                        }
                    },
                    none => {}
                }
            },
            none => {}
        },
        none => {}
    }
}

pub fn value_symbol_ref(ctx: InferCtx, def_id: Int) -> SymbolRef {
    let source = match ctx.value_symbols.get(def_id) {
        some(symbol) => symbol,
        none => panic("value identity: callable DefId has no resolver SymbolRef")
    }
    match compiler_owned_extern_symbol(ctx.env, source) {
        some(exact) => exact,
        none => source
    }
}

pub fn record_value_symbol_ref(
    mut ctx: InferCtx, local_name: Str, symbol: SymbolRef
) {
    match ctx.env.lookup(local_name) {
        some(scheme) => match scheme.def_id {
            some(def_id) => match ctx.value_symbols.get(def_id) {
                some(existing) => if !symbol_ref_same(existing, symbol) {
                    panic("value identity: explicit SymbolRef changed")
                },
                none => ctx.value_symbols.insert(def_id, symbol)
            },
            none => panic("value identity: explicit callable has no DefId")
        },
        none => panic("value identity: explicit callable is not registered")
    }
}

pub fn source_value_symbol_for_decl(
    ctx: InferCtx, decl_index: Int
) -> SymbolRef {
    if decl_index < 0 {
        panic("value identity: declaration index is negative")
    }
    let file_key = match ctx.struct_identity_file_key {
        some(value) => value,
        none => panic("value identity: resolver ledger is absent")
    }
    let frame_index = match ctx.struct_identity_frame_stack.get(
            ctx.struct_identity_frame_stack.len() - 1) {
        some(value) => value,
        none => panic("value identity: registration frame is absent")
    }
    let site_path = "frame:${frame_index}|item:${decl_index}"
    let mut found: SymbolRef? = none
    for entry in ctx.value_symbols_by_payload.entries() {
        let symbol = entry.1
        if symbol_ref_origin_module_key(symbol) == file_key &&
           namespace_kind_same(
                symbol_ref_namespace_kind(symbol), namespace_value()) &&
           symbol_ref_declaration_site_path(symbol) == site_path {
            if found.is_some() {
                panic("value identity: declaration site has two value symbols")
            }
            found = some(symbol)
        }
    }
    match found {
        some(symbol) => symbol,
        none => panic("value identity: declaration site has no resolver symbol")
    }
}

pub fn source_type_alias_symbol_for_decl(
    ctx: InferCtx, decl_index: Int
) -> SymbolRef {
    if decl_index < 0 {
        panic("type alias identity: declaration index is negative")
    }
    let file_key = match ctx.struct_identity_file_key {
        some(value) => value,
        none => panic("type alias identity: resolver ledger is absent")
    }
    let frame_index = match ctx.struct_identity_frame_stack.get(
            ctx.struct_identity_frame_stack.len() - 1) {
        some(value) => value,
        none => panic("type alias identity: registration frame is absent")
    }
    let site_path = "frame:${frame_index}|item:${decl_index}"
    let mut found: SymbolRef? = none
    match ctx.project_namespace_bindings.get(frame_index) {
        some(bindings) => {
            for binding in bindings {
                match binding.namespace {
                    NamespaceKind::TypeAlias => {
                        let symbol = binding.symbol
                        if binding.file_key == file_key &&
                           binding.frame_index == frame_index &&
                           symbol_ref_origin_module_key(symbol) == file_key &&
                           namespace_kind_same(
                               symbol_ref_namespace_kind(symbol),
                               namespace_nominal()) &&
                           symbol_ref_declaration_site_path(symbol) == site_path {
                            if found.is_some() {
                                panic(
                                    "type alias identity: declaration site has two symbols")
                            }
                            found = some(symbol)
                        }
                    },
                    _ => {}
                }
            }
        },
        none => {}
    }
    match found {
        some(symbol) => symbol,
        none => panic(
            "type alias identity: declaration site has no resolver symbol")
    }
}

pub fn commit_final_prelude_value_symbol_ref(
    mut ctx: InferCtx, local_name: Str, symbol: SymbolRef
) {
    match ctx.env.lookup(local_name) {
        some(scheme) => match scheme.def_id {
            some(def_id) => {
                match ctx.value_symbols.get(def_id) {
                    some(existing) => if !symbol_ref_same(existing, symbol) &&
                            !symbol_ref_is_prelude(existing) {
                        panic("value identity: final prelude DefId has non-prelude source")
                    },
                    none => {}
                }
                ctx.value_symbols.insert(def_id, symbol)
            },
            none => panic("value identity: final prelude callable has no DefId")
        },
        none => panic("value identity: final prelude callable is not registered")
    }
}

pub fn current_identity_file_key(ctx: InferCtx) -> Str {
    match ctx.impl_check_frame_stack.get(
            ctx.impl_check_frame_stack.len() - 1) {
        some(frame) => frame.0,
        none => match ctx.struct_identity_file_key {
            some(file_key) => file_key,
            none => panic("value identity: no active resolver/check file")
        }
    }
}

pub fn current_impl_check_site(ctx: InferCtx) -> (Str, Int) {
    match ctx.impl_check_frame_stack.get(
            ctx.impl_check_frame_stack.len() - 1) {
        some(frame) => frame,
        none => panic("executable identity: declaration outside check frame")
    }
}

pub fn enter_executable_owner(mut ctx: InferCtx, value: ExecutableRef) {
    ctx.handled_evidence_frame_bases.push(
        ctx.handled_evidence_frames.len())
    ctx.executable_stack.push(value)
    ctx.dictionary_evidence_owner_stack.push(value)
    ctx.anonymous_child_counters.push(0)
    ctx.semantic_site_counters.push(0)
    ctx.handled_evidence_bindings_stack.push([])
    ctx.handled_evidence_captures_stack.push([])
    ctx.handled_evidence_frames.push([])
}

pub fn exit_executable_owner(mut ctx: InferCtx) {
    if ctx.executable_stack.pop().is_none() ||
       ctx.dictionary_evidence_owner_stack.pop().is_none() ||
       ctx.anonymous_child_counters.pop().is_none() {
        panic("executable identity: owner stack underflow")
    }
    if ctx.semantic_site_counters.pop().is_none() {
        panic("semantic identity: site stack underflow")
    }
    if ctx.handled_evidence_bindings_stack.pop().is_none() ||
       ctx.handled_evidence_captures_stack.pop().is_none() {
        panic("handled evidence: executable stack underflow")
    }
    let frame_base = match ctx.handled_evidence_frame_bases.pop() {
        some(value) => value,
        none => panic("handled evidence: frame base underflow")
    }
    while ctx.handled_evidence_frames.len() > frame_base {
        ctx.handled_evidence_frames.pop()
    }
}

pub fn current_executable_owner(ctx: InferCtx) -> ExecutableRef {
    match ctx.executable_stack.last() {
        some(value) => value,
        none => panic("executable identity: no current body owner")
    }
}

pub fn executable_effect_origin(value: ExecutableRef) -> OriginRef {
    if executable_ref_is_named(value) {
        make_symbol_origin_ref(executable_ref_named_symbol(value))
    } else {
        make_path_origin_ref(executable_ref_anonymous_path(value))
    }
}

pub fn local_effect_header_origin(ctx: InferCtx, def_id: Int) -> OriginRef {
    if def_id < 0 {
        panic("effect header registry: local DefId is synthetic")
    }
    let owner = path_owner_for_module_body(make_module_body_ref(
        current_identity_file_key(ctx), "typed-effect-locals"))
    make_path_origin_ref(make_path_ref(
        owner, ["def:${def_id.to_str()}"], path_role_declaration()))
}

pub fn define_exact_effect_header(
    mut ctx: InferCtx, owner: OriginRef, headers: List<Type>,
    quantified: List<Int>
) -> TypedEffectHeaderSchema {
    define_effect_header_schema(ctx.env, owner, headers, quantified)
}

pub fn publish_exact_callable_effect_header(
    mut ctx: InferCtx, executable: ExecutableRef, signature: Type,
    schema: TypedEffectHeaderSchema
) {
    publish_effect_header_schema(ctx.env, schema)
    match signature {
        Type::FnType { effects, .. } => register_callable_effect_header(
            ctx.env, executable, effects),
        _ => panic("effect header registry: callable header is not FnType")
    }
}

pub fn current_dictionary_evidence_owner(ctx: InferCtx) -> ExecutableRef {
    match ctx.dictionary_evidence_owner_stack.last() {
        some(value) => value,
        none => panic("dictionary evidence: no current runtime owner")
    }
}

pub fn inherit_dictionary_evidence_owner(
    mut ctx: InferCtx, value: ExecutableRef
) {
    let index = ctx.dictionary_evidence_owner_stack.len() - 1
    if index < 0 {
        panic("dictionary evidence: no executable frame to inherit")
    }
    ctx.dictionary_evidence_owner_stack.set(index, value)
}

fn copy_handled_evidence_refs(
    values: List<HandledEvidenceRef>
) -> List<HandledEvidenceRef> {
    let mut result: List<HandledEvidenceRef> = []
    for value in values { result.push(value) }
    result
}

fn copy_handled_evidence_captures(
    values: List<HandledEvidenceCapture>
) -> List<HandledEvidenceCapture> {
    let mut result: List<HandledEvidenceCapture> = []
    for value in values { result.push(value) }
    result
}

pub fn current_handled_evidence_bindings(
    ctx: InferCtx
) -> List<HandledEvidenceRef> {
    match ctx.handled_evidence_bindings_stack.last() {
        some(values) => copy_handled_evidence_refs(values),
        none => panic("handled evidence: no current executable bindings")
    }
}

pub fn current_handled_evidence_captures(
    ctx: InferCtx
) -> List<HandledEvidenceCapture> {
    match ctx.handled_evidence_captures_stack.last() {
        some(values) => copy_handled_evidence_captures(values),
        none => panic("handled evidence: no current executable captures")
    }
}

fn handled_evidence_site(
    executable: ExecutableRef, label: Str, ordinal: Int,
    role: PathRole
) -> PathRef {
    let (owner, prefix) = if executable_ref_is_named(executable) {
        (path_owner_for_symbol(executable_ref_named_symbol(executable)), [])
    } else {
        let path = executable_ref_anonymous_path(executable)
        (path_ref_owner(path), path_ref_normalized_child_path(path))
    }
    let mut child_path = prefix.map(fn(value) { value })
    child_path.push("${label}:${ordinal.to_str()}")
    make_path_ref(owner, child_path, role)
}

fn make_handled_evidence_for_executable(
    requirement: HandledEffectRef, executable: ExecutableRef,
    kind: BinderKind, label: Str, path_ordinal: Int,
    contract_ordinal: Int,
    role: PathRole
) -> HandledEvidenceRef {
    let site = handled_evidence_site(
        executable, label, path_ordinal, role)
    let binding = make_semantic_evidence_binder(
        make_synthetic_slot_ref(site), executable, kind, site)
    make_handled_evidence_ref(
        requirement, binding, executable, contract_ordinal)
}

fn make_current_handled_evidence(
    ctx: InferCtx, requirement: HandledEffectRef,
    kind: BinderKind, label: Str, path_ordinal: Int,
    contract_ordinal: Int, role: PathRole
) -> HandledEvidenceRef {
    make_handled_evidence_for_executable(
        requirement, current_executable_owner(ctx), kind, label,
        path_ordinal, contract_ordinal, role)
}

fn append_current_handled_evidence_inventory(
    mut ctx: InferCtx, value: HandledEvidenceRef
) {
    let stack_index = ctx.handled_evidence_bindings_stack.len() - 1
    let mut bindings = ctx.handled_evidence_bindings_stack.get(
        stack_index).unwrap()
    bindings.push(value)
    ctx.handled_evidence_bindings_stack.set(stack_index, bindings)
}

fn append_current_handled_evidence_binding(
    mut ctx: InferCtx, value: HandledEvidenceRef
) {
    append_current_handled_evidence_inventory(ctx, value)
    let frame_index = ctx.handled_evidence_frame_bases.last().unwrap()
    let mut frame = ctx.handled_evidence_frames.get(frame_index).unwrap()
    frame.push(value)
    ctx.handled_evidence_frames.set(frame_index, frame)
}

fn capture_outer_handled_evidence(
    mut ctx: InferCtx, source: HandledEvidenceRef
) -> HandledEvidenceRef {
    let capture_index = ctx.handled_evidence_captures_stack.len() - 1
    let mut captures = ctx.handled_evidence_captures_stack.get(
        capture_index).unwrap()
    let path_ordinal = captures.len()
    let contract_ordinal = current_handled_evidence_bindings(ctx).len()
    let target = make_current_handled_evidence(
        ctx, handled_evidence_requirement(source),
        binder_kind_handled_evidence_capture(),
        "handled-evidence-capture", path_ordinal, contract_ordinal,
        path_role_capture())
    captures.push(make_handled_evidence_capture(
        handled_evidence_requirement(source), source, target))
    ctx.handled_evidence_captures_stack.set(capture_index, captures)
    append_current_handled_evidence_inventory(ctx, target)
    let frame_index = ctx.handled_evidence_frame_bases.last().unwrap()
    let mut frame = ctx.handled_evidence_frames.get(frame_index).unwrap()
    frame.push(target)
    ctx.handled_evidence_frames.set(frame_index, frame)
    target
}

pub fn resolve_handled_evidence(
    mut ctx: InferCtx, requirement: HandledEffectRef
) -> HandledEvidenceRef {
    let current = current_executable_owner(ctx)
    let mut frame_index = ctx.handled_evidence_frames.len() - 1
    while frame_index >= 0 {
        let frame = ctx.handled_evidence_frames.get(frame_index).unwrap()
        let mut item_index = frame.len() - 1
        while item_index >= 0 {
            let candidate = frame.get(item_index).unwrap()
            if handled_effect_ref_same(
                    handled_evidence_requirement(candidate), requirement) {
                if executable_ref_same(
                        handled_evidence_contract_owner(candidate), current) {
                    return candidate
                }
                return capture_outer_handled_evidence(ctx, candidate)
            }
            item_index = item_index - 1
        }
        frame_index = frame_index - 1
    }
    if ctx.executable_stack.len() > 1 {
        let parent_stack_index = ctx.executable_stack.len() - 2
        let parent = ctx.executable_stack.get(parent_stack_index).unwrap()
        let mut parent_bindings = ctx.handled_evidence_bindings_stack.get(
            parent_stack_index).unwrap()
        let parent_ordinal = parent_bindings.len()
        let source = make_handled_evidence_for_executable(
            requirement, parent,
            binder_kind_handled_evidence_param(),
            "handled-evidence-param", parent_ordinal, parent_ordinal,
            path_role_parameter())
        parent_bindings.push(source)
        ctx.handled_evidence_bindings_stack.set(
            parent_stack_index, parent_bindings)
        let parent_frame_index = ctx.handled_evidence_frame_bases.get(
            parent_stack_index).unwrap()
        let mut parent_frame = ctx.handled_evidence_frames.get(
            parent_frame_index).unwrap()
        parent_frame.push(source)
        ctx.handled_evidence_frames.set(parent_frame_index, parent_frame)
        return capture_outer_handled_evidence(ctx, source)
    }
    let ordinal = current_handled_evidence_bindings(ctx).len()
    let binding = make_current_handled_evidence(
        ctx, requirement, binder_kind_handled_evidence_param(),
        "handled-evidence-param", ordinal, ordinal,
        path_role_parameter())
    append_current_handled_evidence_binding(ctx, binding)
    binding
}

fn callable_handled_requirements(
    effects: EffectRow
) -> List<HandledEffectRef> {
    let mut result: List<HandledEffectRef> = []
    for atom in effects.effects {
        match atom {
            Effect::CustomEffect { reference, .. } => {
                if result.any(fn(existing) {
                        handled_effect_ref_same(existing, reference)
                    }) {
                    panic("handled evidence: callable requirement repeats")
                }
                result.push(reference)
            },
            _ => {}
        }
    }
    result
}

pub fn prepare_callable_handled_evidence(
    mut ctx: InferCtx, declared_effects: EffectRow
) {
    for requirement in callable_handled_requirements(declared_effects) {
        let _ = resolve_handled_evidence(ctx, requirement)
    }
}

pub fn canonicalize_callable_handled_evidence(
    mut ctx: InferCtx, final_effects: EffectRow
) -> (List<HandledEvidenceRef>, List<HandledEvidenceRef>) {
    let requirements = callable_handled_requirements(final_effects)
    let existing = current_handled_evidence_bindings(ctx)
    let current = current_executable_owner(ctx)
    let mut sources: List<HandledEvidenceRef> = []
    let mut targets: List<HandledEvidenceRef> = []
    for index in 0..requirements.len() {
        let requirement = requirements.get(index).unwrap()
        let mut found: HandledEvidenceRef? = none
        for value in existing {
            if handled_effect_ref_same(
                    handled_evidence_requirement(value), requirement) {
                if found.is_some() {
                    panic("handled evidence: callable requirement is ambiguous")
                }
                found = some(value)
            }
        }
        let source = match found {
            some(value) => value,
            none => panic(
                "handled evidence: final callable requirement was not produced")
        }
        if !executable_ref_same(
                handled_evidence_contract_owner(source), current) {
            panic("handled evidence: final binding owner differs")
        }
        let kind = binder_entry_kind(handled_evidence_binding(source))
        let kind_tag = binder_kind_tag(kind)
        let target = if kind_tag == binder_kind_tag(
                binder_kind_handled_evidence_param()) {
            make_current_handled_evidence(
                ctx, requirement, binder_kind_handled_evidence_param(),
                "handled-evidence-param", index, index,
                path_role_parameter())
        } else if kind_tag == binder_kind_tag(
                binder_kind_handled_evidence_capture()) {
            make_current_handled_evidence(
                ctx, requirement, binder_kind_handled_evidence_capture(),
                "handled-evidence-capture", index, index,
                path_role_capture())
        } else {
            panic("handled evidence: callable inventory contains a local")
        }
        sources.push(source)
        targets.push(target)
    }

    let capture_index = ctx.handled_evidence_captures_stack.len() - 1
    let existing_captures = ctx.handled_evidence_captures_stack.get(
        capture_index).unwrap()
    let mut captures: List<HandledEvidenceCapture> = []
    for index in 0..sources.len() {
        let source = sources.get(index).unwrap()
        let target = targets.get(index).unwrap()
        if binder_kind_tag(binder_entry_kind(
                handled_evidence_binding(source))) ==
                binder_kind_tag(binder_kind_handled_evidence_capture()) {
            let mut found: HandledEvidenceCapture? = none
            for capture in existing_captures {
                if handled_evidence_ref_same(
                        handled_evidence_capture_target(capture), source) {
                    if found.is_some() {
                        panic("handled evidence: capture target repeats")
                    }
                    found = some(capture)
                }
            }
            let capture = match found {
                some(value) => value,
                none => panic("handled evidence: capture relation is absent")
            }
            captures.push(make_handled_evidence_capture(
                handled_evidence_capture_requirement(capture),
                handled_evidence_capture_source(capture), target))
        }
    }
    ctx.handled_evidence_captures_stack.set(capture_index, captures)
    let binding_index = ctx.handled_evidence_bindings_stack.len() - 1
    ctx.handled_evidence_bindings_stack.set(
        binding_index, copy_handled_evidence_refs(targets))
    let frame_index = ctx.handled_evidence_frame_bases.last().unwrap()
    if ctx.handled_evidence_frames.len() != frame_index + 1 {
        panic("handled evidence: callable finalized with an installed frame")
    }
    ctx.handled_evidence_frames.set(
        frame_index, copy_handled_evidence_refs(targets))
    (sources, targets)
}

pub fn install_handled_evidence(
    mut ctx: InferCtx, requirements: List<HandledEffectRef>
) -> List<HandledEvidenceRef> {
    let mut installed: List<HandledEvidenceRef> = []
    let counter_index = ctx.semantic_site_counters.len() - 1
    for requirement in requirements {
        if installed.any(fn(existing) {
                handled_effect_ref_same(
                    handled_evidence_requirement(existing), requirement)
            }) {
            continue
        }
        let ordinal = ctx.semantic_site_counters.get(counter_index).unwrap()
        ctx.semantic_site_counters.set(counter_index, ordinal + 1)
        installed.push(make_current_handled_evidence(
            ctx, requirement, binder_kind_handled_evidence_local(),
            "handled-evidence-local", ordinal, ordinal,
            path_role_handler()))
    }
    ctx.handled_evidence_frames.push(
        copy_handled_evidence_refs(installed))
    installed
}

pub fn uninstall_handled_evidence(mut ctx: InferCtx) {
    let base = ctx.handled_evidence_frame_bases.last().unwrap()
    if ctx.handled_evidence_frames.len() <= base + 1 {
        panic("handled evidence: no installed frame")
    }
    ctx.handled_evidence_frames.pop()
}

pub fn fresh_child_executable(mut ctx: InferCtx, role: Str) -> ExecutableRef {
    if role.len() == 0 { panic("executable identity: empty child role") }
    let parent = current_executable_owner(ctx)
    let counter_index = ctx.anonymous_child_counters.len() - 1
    let ordinal = ctx.anonymous_child_counters.get(
        counter_index).unwrap_or(0)
    ctx.anonymous_child_counters.set(counter_index, ordinal + 1)
    let (owner, prefix) = if executable_ref_is_named(parent) {
        (path_owner_for_symbol(executable_ref_named_symbol(parent)), [])
    } else {
        let path = executable_ref_anonymous_path(parent)
        (path_ref_owner(path), path_ref_normalized_child_path(path))
    }
    let mut child_path = prefix.map(fn(value) { value })
    child_path.push("${role}:${ordinal}")
    make_anonymous_executable_ref(make_path_ref(
        owner, child_path, path_role_child()))
}

pub fn executable_capture_slot(
    executable: ExecutableRef, capture_ordinal: Int
) -> SlotRef {
    if capture_ordinal < 0 {
        panic("executable identity: negative capture ordinal")
    }
    let (owner, prefix) = if executable_ref_is_named(executable) {
        (path_owner_for_symbol(executable_ref_named_symbol(executable)), [])
    } else {
        let path = executable_ref_anonymous_path(executable)
        (path_ref_owner(path), path_ref_normalized_child_path(path))
    }
    let mut child_path = prefix.map(fn(value) { value })
    child_path.push("capture:${capture_ordinal}")
    make_synthetic_slot_ref(make_path_ref(
        owner, child_path, path_role_capture()))
}

fn semantic_declaration_binder(
    ctx: InferCtx, def_id: Int, kind: BinderKind, label: Str
) -> BinderEntry {
    if label.len() == 0 {
        panic("semantic binder: empty role label")
    }
    let executable = current_executable_owner(ctx)
    let slot = make_source_slot_ref(
        current_identity_file_key(ctx), slot_domain_lexical(), def_id)
    let (owner, prefix) = if executable_ref_is_named(executable) {
        (path_owner_for_symbol(executable_ref_named_symbol(executable)), [])
    } else {
        let path = executable_ref_anonymous_path(executable)
        (path_ref_owner(path), path_ref_normalized_child_path(path))
    }
    let mut child_path = prefix.map(fn(value) { value })
    child_path.push("semantic:${label}:${def_id.to_str()}")
    let site = make_path_ref(owner, child_path, path_role_declaration())
    make_source_binder_entry(slot, executable, kind, site)
}

pub fn fresh_semantic_let_binder(
    mut ctx: InferCtx, label: Str
) -> BinderEntry {
    let def_id = ctx.env.fresh_def_id()
    semantic_declaration_binder(ctx, def_id, binder_kind_let(), label)
}

pub fn fresh_semantic_var_binder(
    mut ctx: InferCtx, label: Str
) -> BinderEntry {
    let def_id = ctx.env.fresh_def_id()
    semantic_declaration_binder(ctx, def_id, binder_kind_var(), label)
}

pub fn semantic_for_binder(
    ctx: InferCtx, def_id: Int, label: Str
) -> BinderEntry {
    semantic_declaration_binder(ctx, def_id, binder_kind_for(), label)
}

pub fn semantic_destructure_binder(
    ctx: InferCtx, def_id: Int, label: Str
) -> BinderEntry {
    semantic_declaration_binder(
        ctx, def_id, binder_kind_destructure(), label)
}

pub fn semantic_parameter_binder(
    ctx: InferCtx, executable: ExecutableRef,
    def_id: Int, index: Int, label: Str
) -> BinderEntry {
    if index < 0 || label.len() == 0 {
        panic("semantic parameter binder: invalid index/label")
    }
    let slot = make_source_slot_ref(
        current_identity_file_key(ctx), slot_domain_lexical(), def_id)
    let (owner, prefix) = if executable_ref_is_named(executable) {
        (path_owner_for_symbol(executable_ref_named_symbol(executable)), [])
    } else {
        let path = executable_ref_anonymous_path(executable)
        (path_ref_owner(path), path_ref_normalized_child_path(path))
    }
    let mut child_path = prefix.map(fn(value) { value })
    child_path.push("parameter:${label}:${index.to_str()}")
    make_source_binder_entry(
        slot, executable, binder_kind_source_param(),
        make_path_ref(owner, child_path, path_role_parameter()))
}

pub fn fresh_semantic_path(mut ctx: InferCtx, label: Str) -> PathRef {
    if label.len() == 0 { panic("semantic identity: empty site label") }
    let executable = current_executable_owner(ctx)
    let counter_index = ctx.semantic_site_counters.len() - 1
    let ordinal = ctx.semantic_site_counters.get(
        counter_index).unwrap_or(0)
    ctx.semantic_site_counters.set(counter_index, ordinal + 1)
    let (owner, prefix) = if executable_ref_is_named(executable) {
        (path_owner_for_symbol(executable_ref_named_symbol(executable)), [])
    } else {
        let path = executable_ref_anonymous_path(executable)
        (path_ref_owner(path), path_ref_normalized_child_path(path))
    }
    let mut child_path = prefix.map(fn(value) { value })
    child_path.push("semantic:${label}:${ordinal.to_str()}")
    make_path_ref(owner, child_path, path_role_synthetic())
}

pub fn value_binding_kind(ctx: InferCtx, def_id: Int?) -> ValueBindingKind {
    match def_id {
        some(id) => match ctx.value_binding_kinds.get(id) {
            some(kind) => kind,
            none => ValueBindingKind::LocalBorrow
        },
        none => ValueBindingKind::LocalBorrow
    }
}

fn type_has_error(t: Type) -> Bool {
    match t {
        Type::ErrorType => true,
        Type::FnType { params, return_type, effects } => {
            for p in params { if type_has_error(p) { return true } }
            if type_has_error(return_type) { return true }
            for eff in effects.effects {
                match eff {
                    Effect::FailEffect { error_type } =>
                        if type_has_error(error_type) { return true },
                    Effect::MutEffect { state_type } =>
                        if type_has_error(state_type) { return true },
                    Effect::CustomEffect { type_args, .. } => {
                        for a in type_args { if type_has_error(a) { return true } }
                    },
                    _ => {}
                }
            }
            false
        },
        Type::StructType { type_params, .. } => {
            for p in type_params { if type_has_error(p) { return true } }
            false
        },
        Type::EnumType { type_params, .. } => {
            for p in type_params { if type_has_error(p) { return true } }
            false
        },
        Type::GenericType { base, args } => {
            if type_has_error(base) { return true }
            for a in args { if type_has_error(a) { return true } }
            false
        },
        Type::RecordType { fields, .. } => {
            for f in fields { if type_has_error(f.ty) { return true } }
            false
        },
        Type::EffectRowType { effects, .. } => {
            for eff in effects {
                match eff {
                    Effect::FailEffect { error_type } =>
                        if type_has_error(error_type) { return true },
                    Effect::MutEffect { state_type } =>
                        if type_has_error(state_type) { return true },
                    Effect::CustomEffect { type_args, .. } => {
                        for a in type_args { if type_has_error(a) { return true } }
                    },
                    _ => {}
                }
            }
            false
        },
        Type::TupleType { elements } => {
            for e in elements { if type_has_error(e) { return true } }
            false
        },
        Type::PtrType { pointee } => type_has_error(pointee),
        _ => false
    }
}

fn resolve_named_impl_dict_evidence(
    runtime_owner: ExecutableRef,
    env: TypeEnv, current_fn_bounds: List<FnBoundsEntry>,
    name: Str, type_params: List<Type>, s: UnionFind, trait_name: Str
) -> DictEvidenceResolution {
    match find_impl(env.trait_reg, name, trait_name) {
        none => {
            let mut suppress = false
            for type_param in type_params {
                if type_has_error(type_param) { suppress = true }
            }
            DictEvidenceResolution::Missing {
                suppress_diagnostic: suppress
            }
        },
        some(impl_entry) => {
            let impl_owner = match impl_entry.owner_ref {
                some(value) => value,
                none => panic("dictionary evidence: impl owner is absent")
            }
            let dict_name = trait_dict_name(name, trait_name)
            let requirements = match instantiate_impl_runtime_requirements(
                impl_entry, type_params
            ) {
                some(resolved) => resolved,
                none => return DictEvidenceResolution::Missing {
                    suppress_diagnostic: false
                }
            }
            if requirements.len() == 0 {
                return DictEvidenceResolution::Resolved {
                    dict_ref: make_static_dict_ref(
                        dict_name, make_exact_static_dict_ref(impl_owner))
                }
            }

            let mut inner_dicts: List<DictRef> = []
            let mut has_pending = false
            let mut has_missing = false
            let mut suppress_missing = true
            for requirement in requirements {
                match resolve_dict_evidence_for_type(
                    runtime_owner, env, current_fn_bounds,
                    requirement.subject_type, s,
                    requirement.canonical_trait_name
                ) {
                    DictEvidenceResolution::Resolved { dict_ref } => {
                        let assoc_valid = match find_matching_fn_bound(
                            current_fn_bounds, requirement.subject_type, s,
                            requirement.canonical_trait_name
                        ) {
                            some(bound) => impl_assoc_constraints_match_fn_bound(
                                requirement.assoc_constraints, bound,
                                map_new(), s),
                            none => impl_assoc_constraints_match_concrete(
                                env, requirement.subject_type,
                                requirement.canonical_trait_name,
                                requirement.assoc_constraints,
                                map_new(), s)
                        }
                        if assoc_valid {
                            inner_dicts.push(dict_ref)
                        } else {
                            has_missing = true
                            suppress_missing = false
                        }
                    },
                    DictEvidenceResolution::Pending => {
                        has_pending = true
                    },
                    DictEvidenceResolution::Missing { suppress_diagnostic } => {
                        has_missing = true
                        if !suppress_diagnostic { suppress_missing = false }
                    }
                }
            }
            if has_missing {
                return DictEvidenceResolution::Missing {
                    suppress_diagnostic: suppress_missing
                }
            }
            if has_pending { return DictEvidenceResolution::Pending }
            let trait_ref = match env.trait_reg.traits.get(trait_name) {
                some(definition) => registered_trait_ref_symbol(
                    definition.owner_ref),
                none => panic("dictionary evidence: exact trait owner is absent")
            }
            DictEvidenceResolution::Resolved { dict_ref:
                make_wrapped_dict_ref(
                    dict_name, trait_ref, inner_dicts,
                    make_exact_wrapped_dict_ref(
                        impl_owner, inner_dicts.map(fn(value) {
                            dict_ref_exact(value)
                        }))) }
        }
    }
}

fn resolve_dict_evidence_for_type(
    runtime_owner: ExecutableRef,
    env: TypeEnv, current_fn_bounds: List<FnBoundsEntry>,
    t: Type, s: UnionFind, trait_name: Str
) -> DictEvidenceResolution {
    let concrete = apply_subst(s, t)
    match concrete {
        Type::TypeVar { id, .. } => match resolve_fn_bound_dict_ref(
            runtime_owner, current_fn_bounds, id, s, trait_name
        ) {
            some(dict_ref) => DictEvidenceResolution::Resolved {
                dict_ref: dict_ref
            },
            none => DictEvidenceResolution::Pending
        },
        Type::StructType { name, type_params, .. } =>
            resolve_named_impl_dict_evidence(
                runtime_owner, env, current_fn_bounds,
                name, type_params, s, trait_name),
        Type::EnumType { name, type_params, .. } =>
            resolve_named_impl_dict_evidence(
                runtime_owner, env, current_fn_bounds,
                name, type_params, s, trait_name),
        Type::ErrorType => DictEvidenceResolution::Missing {
            suppress_diagnostic: true
        },
        _ => {
            match type_to_builtin_name(concrete) {
                some(builtin_name) => {
                    match find_impl(env.trait_reg, builtin_name, trait_name) {
                        some(impl_entry) => {
                            let impl_owner = match impl_entry.owner_ref {
                                some(value) => value,
                                none => panic("dictionary evidence: builtin impl owner is absent")
                            }
                            DictEvidenceResolution::Resolved {
                                dict_ref: make_static_dict_ref(
                                    trait_dict_name(builtin_name, trait_name),
                                    make_exact_static_dict_ref(impl_owner))
                            }
                        },
                        none => DictEvidenceResolution::Missing {
                            suppress_diagnostic: type_has_error(concrete)
                        }
                    }
                },
                none => DictEvidenceResolution::Missing {
                    suppress_diagnostic: type_has_error(concrete)
                }
            }
        }
    }
}

// Resolve exactly the runtime evidence declared by an impl.  Failure is
// propagated to the caller so diagnostics can be emitted at the use site;
// this function never fabricates a base or "__unknown" dictionary.
pub fn resolve_dict_ref_for_type(
    runtime_owner: ExecutableRef,
    env: TypeEnv, current_fn_bounds: List<FnBoundsEntry>,
    t: Type, s: UnionFind, trait_name: Str
) -> DictRef? {
    match resolve_dict_evidence_for_type(
        runtime_owner, env, current_fn_bounds, t, s, trait_name
    ) {
        DictEvidenceResolution::Resolved { dict_ref } => some(dict_ref),
        DictEvidenceResolution::Pending => none,
        DictEvidenceResolution::Missing { .. } => none
    }
}

fn resolve_scheme_evidence(
    runtime_owner: ExecutableRef,
    sink: CollectingSink, env: TypeEnv,
    current_fn_bounds: List<FnBoundsEntry>,
    scheme: TypeScheme, callee_type: Type, s: UnionFind, span: Span,
    report_assoc_mismatch: Bool
) -> SchemeEvidenceResolution {
    if scheme.bounds.len() == 0 {
        return SchemeEvidenceResolution::Resolved {
            dicts: [], assoc_mismatch: false
        }
    }
    let var_map = build_scheme_var_map(scheme, callee_type)
    let mut resolved_dicts: List<DictRef> = []
    let mut pending_failures: List<EvidenceFailure> = []
    let mut missing_failures: List<EvidenceFailure> = []
    let mut assoc_mismatch = false
    for bound in scheme.bounds {
        match var_map.get(bound.type_var) {
            some(fresh_var) => {
                let concrete = apply_subst(s, fresh_var)
                match resolve_dict_evidence_for_type(
                    runtime_owner, env, current_fn_bounds,
                    concrete, s, bound.trait_name
                ) {
                    DictEvidenceResolution::Resolved { dict_ref } => {
                        resolved_dicts.push(dict_ref)
                        // Associated constraints remain immediate: a later
                        // obligation can unlock an earlier pending owner.
                        let assoc_valid = match concrete {
                            Type::StructType { name, .. } =>
                                check_assoc_constraints(
                                    sink, env, bound, name, var_map, s, span,
                                    report_assoc_mismatch),
                            Type::EnumType { name, .. } =>
                                check_assoc_constraints(
                                    sink, env, bound, name, var_map, s, span,
                                    report_assoc_mismatch),
                            _ => match type_to_builtin_name(concrete) {
                                some(name) => check_assoc_constraints(
                                    sink, env, bound, name, var_map, s, span,
                                    report_assoc_mismatch),
                                none => true
                            }
                        }
                        if !assoc_valid { assoc_mismatch = true }
                    },
                    DictEvidenceResolution::Pending =>
                        pending_failures.push(EvidenceFailure {
                            trait_name: bound.trait_name,
                            suppress_diagnostic: false
                        }),
                    DictEvidenceResolution::Missing { suppress_diagnostic } =>
                        missing_failures.push(EvidenceFailure {
                            trait_name: bound.trait_name,
                            suppress_diagnostic: suppress_diagnostic
                        })
                }
            },
            none => missing_failures.push(EvidenceFailure {
                trait_name: bound.trait_name,
                suppress_diagnostic: false
            })
        }
    }
    if missing_failures.len() > 0 {
        SchemeEvidenceResolution::Missing { failures: missing_failures }
    } else if pending_failures.len() > 0 {
        SchemeEvidenceResolution::Pending { failures: pending_failures }
    } else {
        SchemeEvidenceResolution::Resolved {
            dicts: resolved_dicts,
            assoc_mismatch: assoc_mismatch
        }
    }
}

fn report_evidence_failures(
    sink: CollectingSink, failures: List<EvidenceFailure>, span: Span
) {
    for failure in failures {
        if !failure.suppress_diagnostic {
            let trait_display = nominal_display_name(failure.trait_name)
            let _ = type_error(sink, E0503,
                "Type does not satisfy trait bound '${trait_display}'",
                span, DiagnosticContext::TraitError {
                    detail: "type does not satisfy '${trait_display}'"
                })
        }
    }
}

fn purpose_reports_assoc_mismatch(purpose: PendingDictPurpose) -> Bool {
    match purpose {
        PendingDictPurpose::DirectCallPublish { .. } => true,
        PendingDictPurpose::ExternCallValidate => true,
        PendingDictPurpose::CallableValueShadow => false
    }
}

fn purpose_reports_drain_failure(purpose: PendingDictPurpose) -> Bool {
    match purpose {
        PendingDictPurpose::DirectCallPublish { .. } => true,
        PendingDictPurpose::ExternCallValidate => true,
        PendingDictPurpose::CallableValueShadow => false
    }
}

fn publish_resolved_dicts(
    purpose: PendingDictPurpose, dicts: List<DictRef>
) {
    match purpose {
        PendingDictPurpose::DirectCallPublish { output_slot: output } => {
            if output.len() != 0 {
                panic("unreachable: pending dictionary output was filled twice")
            }
            // Publish only after the whole scheme resolved, never a prefix.
            for dict_ref in dicts { output.push(dict_ref) }
        },
        PendingDictPurpose::ExternCallValidate => {},
        PendingDictPurpose::CallableValueShadow => {}
    }
}

pub fn resolve_dicts_from_scheme(
    runtime_owner: ExecutableRef,
    sink: CollectingSink, env: TypeEnv,
    current_fn_bounds: List<FnBoundsEntry>,
    scheme: TypeScheme, callee_type: Type, s: UnionFind, span: Span
) -> List<DictRef> {
    match resolve_scheme_evidence(
        runtime_owner, sink, env, current_fn_bounds,
        scheme, callee_type, s, span, true
    ) {
        SchemeEvidenceResolution::Resolved { dicts, .. } => dicts,
        SchemeEvidenceResolution::Pending { failures } => {
            report_evidence_failures(sink, failures, span)
            []
        },
        SchemeEvidenceResolution::Missing { failures } => {
            report_evidence_failures(sink, failures, span)
            []
        }
    }
}

pub fn resolve_dicts_from_impl_owner(
    runtime_owner: ExecutableRef,
    sink: CollectingSink, env: TypeEnv,
    current_fn_bounds: List<FnBoundsEntry>,
    owner: ImplEntry, method_core: ImplMethodSchemeCore,
    callee_type: Type, s: UnionFind, span: Span
) -> List<DictRef> {
    match resolve_impl_owner_evidence(
        runtime_owner, sink, env, current_fn_bounds, owner, method_core,
        callee_type, s, span, true
    ) {
        SchemeEvidenceResolution::Resolved { dicts, .. } => dicts,
        SchemeEvidenceResolution::Pending { failures } => {
            report_evidence_failures(sink, failures, span)
            []
        },
        SchemeEvidenceResolution::Missing { failures } => {
            report_evidence_failures(sink, failures, span)
            []
        }
    }
}

// Pending-capable call sites hand us their freshly allocated HIR list.  The
// exact same alias is retained by the obligation and populated only after all
// bounds resolve atomically.
pub fn resolve_or_defer_dicts_from_scheme(
    mut ctx: InferCtx, scheme: TypeScheme, callee_type: Type,
    s: UnionFind, span: Span, purpose: PendingDictPurpose
) {
    if scheme.bounds.len() == 0 { return }
    match resolve_scheme_evidence(
        current_dictionary_evidence_owner(ctx),
        ctx.sink, ctx.env, ctx.current_fn_bounds,
        scheme, callee_type, s, span,
        purpose_reports_assoc_mismatch(purpose)
    ) {
        SchemeEvidenceResolution::Resolved { dicts, .. } =>
            publish_resolved_dicts(purpose, dicts),
        SchemeEvidenceResolution::Pending { .. } =>
            ctx.pending_dict_obligations.push(PendingDictObligation {
                runtime_owner: current_dictionary_evidence_owner(ctx),
                source: PendingEvidenceSource::SchemeEvidenceSource(scheme),
                callee_type: callee_type,
                fn_bounds: list_clone(ctx.current_fn_bounds),
                span: span,
                purpose: purpose
            }),
        SchemeEvidenceResolution::Missing { failures } =>
            report_evidence_failures(ctx.sink, failures, span)
    }
}

pub fn resolve_or_defer_dicts_from_impl_owner(
    mut ctx: InferCtx, owner: ImplEntry,
    method_core: ImplMethodSchemeCore, callee_type: Type,
    s: UnionFind, span: Span, purpose: PendingDictPurpose
) {
    if frozen_impl_predicates(owner.predicates).len() == 0 { return }
    match resolve_impl_owner_evidence(
        current_dictionary_evidence_owner(ctx),
        ctx.sink, ctx.env, ctx.current_fn_bounds,
        owner, method_core, callee_type, s, span,
        purpose_reports_assoc_mismatch(purpose)
    ) {
        SchemeEvidenceResolution::Resolved { dicts, .. } =>
            publish_resolved_dicts(purpose, dicts),
        SchemeEvidenceResolution::Pending { .. } =>
            ctx.pending_dict_obligations.push(PendingDictObligation {
                runtime_owner: current_dictionary_evidence_owner(ctx),
                source: PendingEvidenceSource::ImplOwnerEvidenceSource {
                    owner: owner, method_core: method_core
                },
                callee_type: callee_type,
                fn_bounds: list_clone(ctx.current_fn_bounds),
                span: span,
                purpose: purpose
            }),
        SchemeEvidenceResolution::Missing { failures } =>
            report_evidence_failures(ctx.sink, failures, span)
    }
}

// Callable values keep final DictRef attachment in resolve_value_ident.  This
// shadow participates only in the owner's canonical evidence/associated-type
// fixed point, so ordinary shadow failures stay silent until final zonk.
pub fn register_callable_value_shadow(
    mut ctx: InferCtx, scheme: TypeScheme, callee_type: Type,
    s: UnionFind, span: Span
) {
    if scheme.bounds.len() == 0 { return }
    match resolve_scheme_evidence(
        current_dictionary_evidence_owner(ctx),
        ctx.sink, ctx.env, ctx.current_fn_bounds,
        scheme, callee_type, s, span, false
    ) {
        SchemeEvidenceResolution::Resolved { .. } => {},
        SchemeEvidenceResolution::Pending { .. } =>
            ctx.pending_dict_obligations.push(PendingDictObligation {
                runtime_owner: current_dictionary_evidence_owner(ctx),
                source: PendingEvidenceSource::SchemeEvidenceSource(scheme),
                callee_type: callee_type,
                fn_bounds: list_clone(ctx.current_fn_bounds),
                span: span,
                purpose: PendingDictPurpose::CallableValueShadow
            }),
        SchemeEvidenceResolution::Missing { .. } => {}
    }
}

pub fn pending_dict_checkpoint(ctx: InferCtx) -> Int {
    ctx.pending_dict_obligations.len()
}

pub fn has_pending_dicts_since(ctx: InferCtx, checkpoint: Int) -> Bool {
    ctx.pending_dict_obligations.len() > checkpoint
}

// Checker-private owner invariant.  Call it before any successful owner exit
// and after rollback so a leaked suffix cannot become the next owner's
// invisible prefix.
pub fn assert_pending_dict_owner_closed(ctx: InferCtx, checkpoint: Int) {
    if ctx.pending_dict_obligations.len() != checkpoint {
        panic("unreachable: declaration owner leaked pending dictionary obligations")
    }
}

pub fn rollback_pending_dicts(mut ctx: InferCtx, checkpoint: Int) {
    if checkpoint > ctx.pending_dict_obligations.len() {
        panic("unreachable: invalid pending dictionary checkpoint")
    }
    ctx.pending_dict_obligations =
        ctx.pending_dict_obligations.slice(0, checkpoint)
    assert_pending_dict_owner_closed(ctx, checkpoint)
}

// Every successful unlock is monotonic and is attributable to at least one
// scheme-bound or associated-constraint evidence site.  Their total count is
// therefore a finite saturation bound; obligation count alone is unsafe when
// one scheme contains a long reverse-ordered associated-type chain.
fn pending_evidence_attempt_budget(
    obligations: List<PendingDictObligation>
) -> Int {
    let mut evidence_sites = 0
    for obligation in obligations {
        match obligation.source {
            PendingEvidenceSource::SchemeEvidenceSource(scheme) => {
                for bound in scheme.bounds {
                    evidence_sites = evidence_sites + 1
                    evidence_sites = evidence_sites +
                        bound.assoc_constraints.len()
                }
            },
            PendingEvidenceSource::ImplOwnerEvidenceSource { owner, .. } => {
                for predicate in frozen_impl_predicates(owner.predicates) {
                    evidence_sites = evidence_sites + 1
                    evidence_sites = evidence_sites +
                        impl_predicate_assoc_constraints(predicate).len()
                }
            }
        }
    }
    if evidence_sites == 0 { 1 } else { evidence_sites + 1 }
}

// Drain exactly one declaration owner's suffix to the finite evidence-site
// fixed point before diagnosing call/extern failures.  Callable-value shadows
// stay silent here; final zonk remains their diagnostic and attachment owner.
pub fn drain_pending_dicts(
    mut ctx: InferCtx, checkpoint: Int, s: UnionFind
) {
    if checkpoint > ctx.pending_dict_obligations.len() {
        panic("unreachable: invalid pending dictionary checkpoint")
    }
    let mut remaining = ctx.pending_dict_obligations.slice(
        checkpoint, ctx.pending_dict_obligations.len())
    ctx.pending_dict_obligations =
        ctx.pending_dict_obligations.slice(0, checkpoint)

    let max_attempts = pending_evidence_attempt_budget(remaining)
    let mut attempt = 0
    while remaining.len() > 0 && attempt < max_attempts {
        let mut next: List<PendingDictObligation> = []
        for obligation in remaining {
            match resolve_pending_evidence_source(
                obligation.runtime_owner,
                ctx.sink, ctx.env, obligation.fn_bounds,
                obligation.source, obligation.callee_type, s,
                obligation.span,
                purpose_reports_assoc_mismatch(obligation.purpose)
            ) {
                SchemeEvidenceResolution::Resolved { dicts, .. } =>
                    publish_resolved_dicts(obligation.purpose, dicts),
                SchemeEvidenceResolution::Missing { failures } => {
                    if purpose_reports_drain_failure(obligation.purpose) {
                        report_evidence_failures(
                            ctx.sink, failures, obligation.span)
                    }
                },
                SchemeEvidenceResolution::Pending { .. } =>
                    next.push(obligation)
            }
        }
        remaining = next
        attempt = attempt + 1
    }

    // One final observation consumes any resolution made by the last pass;
    // only owners still unresolved here are genuine no-source obligations.
    for obligation in remaining {
        match resolve_pending_evidence_source(
            obligation.runtime_owner,
            ctx.sink, ctx.env, obligation.fn_bounds,
            obligation.source, obligation.callee_type, s,
            obligation.span,
            purpose_reports_assoc_mismatch(obligation.purpose)
        ) {
            SchemeEvidenceResolution::Resolved { dicts, .. } =>
                publish_resolved_dicts(obligation.purpose, dicts),
            SchemeEvidenceResolution::Missing { failures } => {
                if purpose_reports_drain_failure(obligation.purpose) {
                    report_evidence_failures(
                        ctx.sink, failures, obligation.span)
                }
            },
            SchemeEvidenceResolution::Pending { failures } => {
                if purpose_reports_drain_failure(obligation.purpose) {
                    report_evidence_failures(
                        ctx.sink, failures, obligation.span)
                }
            }
        }
    }
}

// Check associated type constraints on a bound against an impl entry's actual
// assoc types.  var_map maps scheme TypeVar ids to instantiation-fresh TypeVars
// so that ac.ty (a scheme-level TypeVar) can be resolved to the call-site var.
fn instantiate_impl_assoc_header(
    mut env: TypeEnv, entry: ImplEntry, name: Str, ty: Type
) -> Type {
    let schema = match entry.assoc_type_effect_schemas.get(name) {
        some(value) => value,
        none => panic("impl assoc effect schema: exact schema is absent")
    }
    instantiate_effect_header_schema(
        env, [ty], schema).0.get(0).unwrap()
}

fn instantiate_struct_field_header(
    mut env: TypeEnv, def: StructDef, field: StructField
) -> Type {
    let schema = def.field_effect_schemas.get(
        field.field_index).unwrap_or_else(fn() {
        panic("struct effect schema: field schema is absent")
    })
    instantiate_effect_header_schema(
        env, [field.ty], schema).0.get(0).unwrap()
}

fn instantiate_enum_field_header(
    mut env: TypeEnv, def: EnumDef,
    variant_index: Int, field_index: Int, field_type: Type
) -> Type {
    let schema = def.variant_field_effect_schemas.get(
        variant_index).unwrap_or_else(fn() {
        panic("enum effect schema: variant schema is absent")
    }).get(field_index).unwrap_or_else(fn() {
        panic("enum effect schema: field schema is absent")
    })
    instantiate_effect_header_schema(
        env, [field_type], schema).0.get(0).unwrap()
}

fn check_assoc_constraints(
    sink: CollectingSink, env: TypeEnv,
    bound: SchemeBound, target_type_name: Str,
    var_map: Map<Int, Type>, s: UnionFind, span: Span,
    report_mismatch: Bool
) -> Bool {
    if bound.assoc_constraints.len() == 0 { return true }
    let mut valid = true
    let impl_entry = find_impl(env.trait_reg, target_type_name, bound.trait_name)
    match impl_entry {
        some(entry) => {
            for ac in bound.assoc_constraints {
                match entry.assoc_types.get(ac.name) {
                    some(actual_ty) => {
                        // B-100 Fix 3: map scheme-level ac.ty through var_map to
                        // get the instantiation-fresh TypeVar, then resolve via s.
                        let mapped_ty = match ac.ty {
                            Type::TypeVar { id, .. } => match var_map.get(id) {
                                some(fresh) => fresh,
                                none => ac.ty,
                            },
                            _ => ac.ty,
                        }
                        let expected_ty = apply_subst(s, mapped_ty)
                        let actual_resolved = apply_subst(
                            s, instantiate_impl_assoc_header(
                                env, entry, ac.name, actual_ty))
                        match expected_ty {
                            Type::TypeVar { .. } => {
                                // Implicit assoc type var — unify with the impl's
                                // concrete type so the caller sees the resolved type.
                                let _ = unify(expected_ty, actual_resolved, s, env) catch { _ => s }
                            },
                            _ => {
                                if !types_equal(expected_ty, actual_resolved) {
                                    valid = false
                                    if report_mismatch {
                                        let _ = type_error(sink, E0513,
                                            "Associated type '${ac.name}' mismatch: expected '${type_to_string(expected_ty)}' but impl provides '${type_to_string(actual_resolved)}'",
                                            span, DiagnosticContext::TraitError { detail: "associated type constraint mismatch" })
                                    }
                                }
                            },
                        }
                    },
                    none => {}
                }
            }
        },
        none => { valid = false }
    }
    valid
}

// ============================================================
// Type expression resolution
// ============================================================

pub fn resolve_type_expr(mut ctx: InferCtx, texpr: TypeExpr) -> Type {
    match texpr {
        TypeExpr::Named { name, qualifier, type_args, span } =>
            match qualifier {
                some(q) => {
                    // Check if qualifier is a type parameter — if so, resolve as associated type
                    match ctx.type_param_scope.get(q) {
                        some(tp_type) => {
                            // q is a type parameter, name is an associated type name
                            resolve_assoc_type(ctx, q, name, span)
                        },
                        none => {
                            let mut resolved_q = q
                            if q == "self" || q.starts_with("super") {
                                match resolve_relative_qualifier(q, ctx.mod_path_stack) {
                                    some(prefix) => { resolved_q = prefix },
                                    none => { resolved_q = q }
                                }
                            }
                            if resolved_q == "" {
                                resolve_named_type(ctx, name, type_args, span)
                            } else {
                                let qualified_type_name = "${resolved_q}::${name}"
                                // Try direct lookup first
                                if ctx.env.types.structs.contains_key(qualified_type_name) || ctx.env.types.enums.contains_key(qualified_type_name) || ctx.env.types.type_aliases.contains_key(qualified_type_name) {
                                    resolve_named_type(ctx, qualified_type_name, type_args, span)
                                } else if ctx.mod_path_stack.len() > 0 {
                                    // Fallback: try prepending current mod path for relative references
                                    let mod_prefix = ctx.mod_path_stack.join("::")
                                    let full_type_name = "${mod_prefix}::${qualified_type_name}"
                                    if ctx.env.types.structs.contains_key(full_type_name) || ctx.env.types.enums.contains_key(full_type_name) || ctx.env.types.type_aliases.contains_key(full_type_name) {
                                        resolve_named_type(ctx, full_type_name, type_args, span)
                                    } else {
                                        resolve_named_type(ctx, qualified_type_name, type_args, span)
                                    }
                                } else {
                                    resolve_named_type(ctx, qualified_type_name, type_args, span)
                                }
                            }
                        }
                    }
                },
                none => resolve_named_type(ctx, name, type_args, span)
            },
        TypeExpr::FnType { params, return_type, effects, .. } => {
            let mut resolved_params: List<Type> = []
            for p in params { resolved_params.push(resolve_type_expr(ctx, p)) }
            let ret = resolve_type_expr(ctx, return_type)
            let eff_row = if effects.len() > 0 {
                let mut resolved_effects: List<Effect> = []
                for e in effects {
                    resolved_effects.push(resolve_effect_expr(ctx, e))
                }
                EffectRow { effects: resolved_effects, tail: none }
            } else {
                let tail_id = ctx.env.fresh_var_id()
                EffectRow { effects: [], tail: some(tail_id) }
            }
            Type::FnType { params: resolved_params, return_type: ret, effects: eff_row }
        },
        TypeExpr::OptionType { inner, .. } =>
            make_option_type(resolve_type_expr(ctx, inner)),
        TypeExpr::RecordType { fields, rest, .. } => {
            let mut resolved_fields: List<RecordField> = []
            for f in fields {
                resolved_fields.push(RecordField { name: f.name, ty: resolve_type_expr(ctx, f.ty) })
            }
            match rest {
                some(rest_name) => {
                    let tail_var = ctx.env.fresh_var()
                    match tail_var {
                        Type::TypeVar { id, .. } => {
                            ctx.type_param_scope.insert(rest_name, tail_var)
                            Type::RecordType { fields: resolved_fields, tail: some(id), tail_name: some(rest_name) }
                        },
                        _ => Type::RecordType { fields: resolved_fields, tail: none, tail_name: none }
                    }
                },
                none => Type::RecordType { fields: resolved_fields, tail: none, tail_name: none }
            }
        },
        TypeExpr::TupleType { elements, .. } => {
            let mut resolved_elems: List<Type> = []
            for e in elements { resolved_elems.push(resolve_type_expr(ctx, e)) }
            Type::TupleType { elements: resolved_elems }
        }
    }
}

// Resolve associated type T::Item by searching the type parameter's trait bounds
fn resolve_assoc_type(mut ctx: InferCtx, type_param_name: Str, assoc_name: Str, span: Span) -> Type {
    // First check: if we have a qualified path (T::Item), look up the qualified_assoc_scope
    // which tracks per-type-param associated types to disambiguate when multiple
    // type params have same-named associated types (e.g., T::Item vs U::Item)
    if type_param_name != "" {
        let qualified_key = "${type_param_name}::${assoc_name}"
        match ctx.qualified_assoc_scope.get(qualified_key) {
            some(ty) => { return ty },
            none => {}
        }
    }

    // Fallback: is the assoc_name already directly in the type_param_scope?
    // (This happens when trait body injects assoc type vars into scope during registration)
    match ctx.type_param_scope.get(assoc_name) {
        some(ty) => {
            // Check if this is a legitimate associated type by verifying through bounds
            // If we're in a trait body context, the associated type name is directly in scope
            return ty
        },
        none => {}
    }

    // Look up the type param's bounds from current_fn_bounds
    let mut found_types: List<Type> = []
    let mut found_trait_names: List<Str> = []
    for fb in ctx.current_fn_bounds {
        if fb.type_param_name == type_param_name {
            // Look up the trait definition for this bound
            match ctx.env.trait_reg.traits.get(fb.trait_name) {
                some(tdef) => {
                    for atdef in tdef.assoc_types {
                        if atdef.name == assoc_name {
                            // Found a matching associated type; create a fresh type variable for it
                            let at_var = ctx.env.fresh_var()
                            found_types.push(at_var)
                            found_trait_names.push(fb.trait_name)
                        }
                    }
                },
                none => {}
            }
        }
    }

    // Also check var_bounds for type variables
    if found_types.len() == 0 {
        match ctx.type_param_scope.get(type_param_name) {
            some(tp_type) => match tp_type {
                Type::TypeVar { id, .. } => {
                    match ctx.env.scope.var_bounds.get(id) {
                        some(bound_set) => {
                            let mut sorted_bounds = bound_set.to_list()
                            sorted_bounds.sort()
                            for bound_name in sorted_bounds {
                                match ctx.env.trait_reg.traits.get(bound_name) {
                                    some(tdef) => {
                                        for atdef in tdef.assoc_types {
                                            if atdef.name == assoc_name {
                                                let at_var = ctx.env.fresh_var()
                                                found_types.push(at_var)
                                                found_trait_names.push(bound_name)
                                            }
                                        }
                                    },
                                    none => {}
                                }
                            }
                        },
                        none => {}
                    }
                },
                _ => {}
            },
            none => {}
        }
    }

    if found_types.len() == 0 {
        let _ = type_error(ctx.sink, E0511,
            "Type '${type_param_name}' has no associated type '${assoc_name}'",
            span, DiagnosticContext::TraitError { detail: "unknown associated type '${assoc_name}'" })
        return ctx.env.fresh_var()
    }
    if found_types.len() > 1 {
        let traits_str = found_trait_names.map(fn(name) { nominal_display_name(name) }).join(", ")
        let _ = type_error(ctx.sink, E0512,
            "Ambiguous associated type '${assoc_name}' for '${type_param_name}': found in traits ${traits_str}",
            span, DiagnosticContext::TraitError { detail: "ambiguous associated type" })
    }
    found_types.get(0).unwrap_or(ctx.env.fresh_var())
}

pub fn resolve_effect_expr(mut ctx: InferCtx, eff: EffectExpr) -> Effect {
    if eff.name == "console" || eff.name == "fs" || eff.name == "process" {
        if eff.type_args.len() != 0 {
            let _ = type_error(ctx.sink, E0407,
                "System effect '${eff.name}' does not accept type arguments",
                eff.span, DiagnosticContext::OtherContext {
                    detail: some("system effect is a closed capability atom") })
            fail.raise(CompileError {})
        }
        let reference = if eff.name == "console" {
            system_effect_console()
        } else if eff.name == "fs" {
            system_effect_fs()
        } else {
            system_effect_process()
        }
        return Effect::SystemEffect { reference: reference }
    }
    if eff.name == "io" {
        let _ = type_error(ctx.sink, E0407,
            "Unknown effect 'io'; use exact system effects console, fs, or process",
            eff.span, DiagnosticContext::OtherContext {
                detail: some("broad io effect was removed from Ring 0.1") })
        fail.raise(CompileError {})
    }
    if eff.name == "unsafe" { return Effect::UnsafeEffect }
    if eff.name == "mut" {
        let mut_state = if eff.type_args.len() > 0 {
            match eff.type_args.first() {
                some(t) => resolve_type_expr(ctx, t),
                none => ctx.env.fresh_var()
            }
        } else {
            ctx.env.fresh_var()
        }
        return Effect::MutEffect { state_type: mut_state }
    }
    if eff.name == "fail" {
        let err_type = if eff.type_args.len() > 0 {
            match eff.type_args.first() {
                some(t) => resolve_type_expr(ctx, t),
                none => ctx.env.fresh_var()
            }
        } else {
            ctx.env.fresh_var()
        }
        return Effect::FailEffect { error_type: err_type }
    }
    // Custom effects: resolve to canonical name from EffectDef
    let (canonical_name, handled_ref) = match ctx.env.types.effects.get(eff.name) {
        some(edef) => match edef.handled_ref {
            some(reference) => (edef.name, reference),
            none => {
                let _ = type_error(ctx.sink, E0407,
                    "Effect '${eff.name}' is not a handled custom effect",
                    eff.span, DiagnosticContext::OtherContext {
                        detail: some("effect class cannot enter handled evidence") })
                fail.raise(CompileError {})
            }
        },
        none => {
            let _ = type_error(ctx.sink, E0407,
                "Unknown effect '${eff.name}'", eff.span,
                DiagnosticContext::OtherContext { detail: some("unknown effect") })
            fail.raise(CompileError {})
        }
    }
    let mut resolved_args: List<Type> = []
    for ta in eff.type_args {
        resolved_args.push(resolve_type_expr(ctx, ta))
    }
    Effect::CustomEffect { reference: handled_ref,
        name: canonical_name, type_args: resolved_args }
}

pub fn resolve_self_type(mut ctx: InferCtx, name: Str) -> Type {
    resolve_named_type(ctx, name, [], span_zero())
}

pub fn resolve_named_type(mut ctx: InferCtx, name: Str, type_args: List<TypeExpr>, span: Span) -> Type {
    if (name == BUILTIN_INT) { return INT }
    if (name == BUILTIN_FLOAT) { return FLOAT }
    if (name == BUILTIN_STR) { return STR }
    if (name == BUILTIN_BOOL) { return BOOL }
    if name == "Never" { return NEVER }
    if name == "Unit" { return UNIT }

    // Check type parameter scope
    match ctx.type_param_scope.get(name) {
        some(tp) => { return tp },
        none => {}
    }

    // Option<T>
    if name == BUILTIN_OPTION && type_args.len() == 1 {
        match type_args.get(0) {
            some(arg) => { return make_option_type(resolve_type_expr(ctx, arg)) },
            none => {}
        }
    }

    // Ptr<T>
    if name == "Ptr" {
        if type_args.len() == 1 {
            match type_args.get(0) {
                some(arg) => { return Type::PtrType { pointee: resolve_type_expr(ctx, arg) } },
                none => {}
            }
        }
        if type_args.len() == 0 {
            return Type::PtrType { pointee: ctx.env.fresh_var() }
        }
    }

    // Known struct
    if ctx.env.types.structs.contains_key(name) {
        match ctx.env.types.structs.get(name) {
            some(def) => {
                if type_args.len() > 0 && type_args.len() != def.type_params.len() {
                    let type_display = nominal_display_name(name)
                    let _ = type_error(ctx.sink, E0301,
                        "Type '${type_display}' expects ${def.type_params.len().to_str()} type argument(s), got ${type_args.len().to_str()}",
                        span, DiagnosticContext::TypeMismatch {
                            expected: "${def.type_params.len().to_str()} type args",
                            actual: "${type_args.len().to_str()} type args",
                            expression: none
                        })
                }
                let mut resolved_params: List<Type> = []
                if type_args.len() > 0 {
                    for a in type_args { resolved_params.push(resolve_type_expr(ctx, a)) }
                } else {
                    for _ in def.type_params { resolved_params.push(ctx.env.fresh_var()) }
                }
                return Type::StructType {
                    name: def.name,
                    type_params: resolved_params
                }
            },
            none => {}
        }
    }

    // Known enum
    if ctx.env.types.enums.contains_key(name) {
        match ctx.env.types.enums.get(name) {
            some(def) => {
                if type_args.len() > 0 && type_args.len() != def.type_params.len() {
                    let type_display = nominal_display_name(name)
                    let _ = type_error(ctx.sink, E0301,
                        "Type '${type_display}' expects ${def.type_params.len().to_str()} type argument(s), got ${type_args.len().to_str()}",
                        span, DiagnosticContext::TypeMismatch {
                            expected: "${def.type_params.len().to_str()} type args",
                            actual: "${type_args.len().to_str()} type args",
                            expression: none
                        })
                }
                let mut resolved_params: List<Type> = []
                if type_args.len() > 0 {
                    for a in type_args { resolved_params.push(resolve_type_expr(ctx, a)) }
                } else {
                    for _ in def.type_params { resolved_params.push(ctx.env.fresh_var()) }
                }
                return Type::EnumType {
                    name: def.name,
                    type_params: resolved_params
                }
            },
            none => {}
        }
    }

    // Type alias
    match ctx.env.types.type_aliases.get(name) {
        some(alias) => {
            if type_args.len() > 0 && type_args.len() != alias.type_params.len() {
                let type_display = nominal_display_name(name)
                let _ = type_error(ctx.sink, E0301,
                    "Type '${type_display}' expects ${alias.type_params.len().to_str()} type argument(s), got ${type_args.len().to_str()}",
                    span, DiagnosticContext::TypeMismatch {
                        expected: "${alias.type_params.len().to_str()} type args",
                        actual: "${type_args.len().to_str()} type args",
                        expression: none
                    })
            }
            let mut resolved_args: List<Type> = []
            // Preserve nullary-alias E0301 recovery: extra syntactic arguments
            // were not recursively diagnosed before. The schema itself is
            // still fully freshened below.
            if alias.type_param_vars.len() > 0 {
                for a in type_args {
                    resolved_args.push(resolve_type_expr(ctx, a))
                }
            }
            return instantiate_type_alias_schema(
                ctx.env, alias, resolved_args)
        },
        none => {}
    }

    let type_display = nominal_display_name(name)
    type_error(ctx.sink, E0204, "Unknown type: ${type_display}", span,
        DiagnosticContext::OtherContext { detail: some("unknown type '${type_display}'") })
}

// ============================================================
// Pattern binding
// ============================================================

struct OrPatternBindingAuthority {
    name: Str,
    scheme: TypeScheme
}

fn collect_or_pattern_binding_names(
    pattern: Pattern, mut names: List<Str>, mut duplicates: List<Str>
) {
    match pattern {
        Pattern::Binding { name, .. } => if name != "_" {
            if names.contains(name) {
                if !duplicates.contains(name) { duplicates.push(name) }
            } else { names.push(name) }
        },
        Pattern::Constructor { fields, .. } => {
            for field in fields {
                collect_or_pattern_binding_names(field, names, duplicates)
            }
        },
        Pattern::NamedConstructor { fields, .. } => {
            for field in fields {
                collect_or_pattern_binding_names(
                    field.pattern, names, duplicates)
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            for element in elements {
                collect_or_pattern_binding_names(element, names, duplicates)
            }
        },
        // Parser chains are flat. A nested OrPattern is its own authority;
        // its first alternative describes the canonical set visible here.
        Pattern::OrPattern { patterns, .. } => match patterns.get(0) {
            some(first) => collect_or_pattern_binding_names(
                first, names, duplicates),
            none => {}
        },
        Pattern::Wildcard { .. } | Pattern::Literal { .. } => {}
    }
}

fn same_or_pattern_binding_names(
    left: List<Str>, right: List<Str>
) -> Bool {
    if left.len() != right.len() { return false }
    for name in left {
        if !right.contains(name) { return false }
    }
    true
}

fn report_duplicate_or_pattern_bindings(
    sink: CollectingSink, duplicates: List<Str>, span: Span
) -> Bool {
    let found = duplicates.len() > 0
    for duplicate in duplicates {
        let _ = type_error(sink, E0301,
            "Pattern repeats binding '${duplicate}'",
            span, DiagnosticContext::OtherContext {
                detail: some("duplicate pattern binding")
            })
    }
    found
}

// Error recovery must preserve lexical scope without attempting any further
// type or constructor resolution. In particular, nested constructor syntax in
// an already-invalid pattern must not emit secondary diagnostics.
fn bind_pattern_recovery(mut ctx: InferCtx, pattern: Pattern) {
    match pattern {
        Pattern::Wildcard { .. } => {},
        Pattern::Binding { name, span } => {
            ctx.env.bind_mono(name, Type::ErrorType)
            match ctx.env.lookup(name) {
                some(scheme) => match scheme.def_id {
                    some(did) => ctx.env.record_def_span(did, span),
                    none => {}
                },
                none => {}
            }
        },
        Pattern::Constructor { fields, .. } => {
            for field in fields {
                bind_pattern_recovery(ctx, field)
            }
        },
        Pattern::Literal { .. } => {},
        Pattern::NamedConstructor { fields, .. } => {
            for field in fields {
                bind_pattern_recovery(ctx, field.pattern)
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            for element in elements {
                bind_pattern_recovery(ctx, element)
            }
        },
        Pattern::OrPattern { patterns, .. } => {
            for alternative in patterns {
                bind_pattern_recovery(ctx, alternative)
            }
        }
    }
}

fn bind_named_pattern_fields_recovery(ctx: InferCtx, fields: List<NamedPatternField>) {
    for field in fields {
        bind_pattern_recovery(ctx, field.pattern)
    }
}

pub fn bind_pattern(mut ctx: InferCtx, pattern: Pattern, expected_type: Type, subst: UnionFind) -> UnionFind {
    match pattern {
        Pattern::Wildcard { .. } => subst,
        Pattern::Binding { name, span } => {
            ctx.env.bind_mono(name, apply_subst(subst, expected_type))
            match ctx.env.lookup(name) {
                some(scheme) => match scheme.def_id {
                    some(did) => ctx.env.record_def_span(did, span),
                    none => {}
                },
                none => {}
            }
            subst
        },
        Pattern::Constructor { name, qualifier, fields, span } =>
            bind_constructor_pattern(ctx, name, qualifier, fields, expected_type, subst, span),
        Pattern::Literal { .. } => subst,
        Pattern::NamedConstructor { name, qualifier, fields, span, .. } =>
            bind_named_constructor_pattern(ctx, name, qualifier, fields, expected_type, subst, span),
        Pattern::TuplePattern { elements, span } => {
            let resolved = apply_subst(subst, expected_type)
            match resolved {
                Type::TupleType { elements: type_elems } => {
                    if elements.len() != type_elems.len() {
                        let _ = type_error(ctx.sink, E0301,
                            "Tuple pattern has ${elements.len().to_str()} elements but type has ${type_elems.len().to_str()}",
                            span, DiagnosticContext::OtherContext { detail: some("tuple arity mismatch") })
                    }
                    let mut s = subst
                    let mut i = 0
                    while i < elements.len() {
                        match (elements.get(i), type_elems.get(i)) {
                            (some(pat), some(ty)) => {
                                s = bind_pattern(ctx, pat, ty, s)
                            },
                            (some(pat), none) => {
                                bind_pattern_recovery(ctx, pat)
                            },
                            _ => {}
                        }
                        i = i + 1
                    }
                    s
                },
                Type::TypeVar { .. } => {
                    let mut element_types: List<Type> = []
                    let mut i = 0
                    while i < elements.len() {
                        element_types.push(ctx.env.fresh_var())
                        i = i + 1
                    }
                    let tuple_type = Type::TupleType { elements: element_types }
                    let mut s = unify_at(ctx.sink, ctx.env, expected_type, tuple_type, subst, span)
                    i = 0
                    while i < elements.len() {
                        match (elements.get(i), element_types.get(i)) {
                            (some(pat), some(ty)) => {
                                s = bind_pattern(ctx, pat, ty, s)
                            },
                            _ => {}
                        }
                        i = i + 1
                    }
                    s
                },
                Type::ErrorType => {
                    for pat in elements {
                        bind_pattern_recovery(ctx, pat)
                    }
                    subst
                },
                _ => {
                    let _ = type_error(ctx.sink, E0301,
                        "Tuple pattern requires tuple type, got ${type_to_string(resolved)}",
                        span, DiagnosticContext::TypeMismatch { expected: "tuple", actual: type_to_string(resolved), expression: none })
                    for pat in elements {
                        bind_pattern_recovery(ctx, pat)
                    }
                    subst
                }
            }
        },
        Pattern::OrPattern { patterns, span } => {
            // Every successful alternative publishes one lexical binding
            // contract: the same names exactly once, compatible types, and
            // the first alternative's one canonical DefId per name.
            if patterns.len() == 0 {
                let _ = type_error(ctx.sink, E0301,
                    "Or-pattern must contain at least one alternative",
                    span, DiagnosticContext::OtherContext {
                        detail: some("empty or-pattern")
                    })
                fail.raise(CompileError {})
            }

            let mut expected_names: List<Str> = []
            let mut has_expected_contract = false
            let mut binding_sets_valid = true
            let mut mismatch_reported = false
            for alternative in patterns {
                let mut names: List<Str> = []
                let mut duplicates: List<Str> = []
                collect_or_pattern_binding_names(
                    alternative, names, duplicates)
                if report_duplicate_or_pattern_bindings(
                        ctx.sink, duplicates, span) {
                    binding_sets_valid = false
                }
                if !has_expected_contract {
                    for name in names { expected_names.push(name) }
                    has_expected_contract = true
                } else if !same_or_pattern_binding_names(
                        expected_names, names) {
                    binding_sets_valid = false
                    if !mismatch_reported {
                        let _ = type_error(ctx.sink, E0301,
                            "Or-pattern alternatives must bind the same variables",
                            span, DiagnosticContext::OtherContext {
                                detail: some("or-pattern binding set mismatch")
                            })
                        mismatch_reported = true
                    }
                }
            }
            if !binding_sets_valid {
                fail.raise(CompileError {})
            }

            let mut s = subst
            let mut authorities: List<OrPatternBindingAuthority> = []
            let mut alternative_index = 0
            for alternative in patterns {
                s = bind_pattern(ctx, alternative, expected_type, s)
                if alternative_index == 0 {
                    for name in expected_names {
                        let scheme = match ctx.env.lookup(name) {
                            some(value) => value,
                            none => panic(
                                "unreachable: validated or-pattern binding is absent from its lexical scope")
                        }
                        match scheme.def_id {
                            some(_) => {},
                            none => panic(
                                "unreachable: canonical or-pattern binding has no exact DefId")
                        }
                        authorities.push(OrPatternBindingAuthority {
                            name: name, scheme: scheme
                        })
                    }
                } else {
                    // The new alternative temporarily owns fresh DefIds.
                    // Unify its types, then restore the first alternative's
                    // scheme so guard/body/HIR see one exact shared slot.
                    for authority in authorities {
                        let candidate = match ctx.env.lookup(authority.name) {
                            some(value) => value,
                            none => panic(
                                "unreachable: validated or-pattern binding is absent from an alternative")
                        }
                        match candidate.def_id {
                            some(_) => {},
                            none => panic(
                                "unreachable: or-pattern alternative binding has no exact DefId")
                        }
                        s = unify_at(ctx.sink, ctx.env,
                            authority.scheme.ty, candidate.ty, s, span)
                    }
                    for authority in authorities {
                        ctx.env.bind(authority.name, authority.scheme)
                    }
                }
                alternative_index = alternative_index + 1
            }
            s
        }
    }
}

pub fn exact_pattern_plan(
    ctx: InferCtx, pattern: Pattern, expected_type: Type, subst: UnionFind
) -> HPatternPlan? {
    let resolved = apply_subst(subst, expected_type)
    match pattern {
        Pattern::Wildcard { .. } => some(h_pattern_wildcard()),
        Pattern::Literal { .. } => some(h_pattern_literal()),
        Pattern::Binding { name, .. } => {
            let scheme = match ctx.env.lookup(name) {
                some(value) => value,
                none => return none
            }
            let def_id = match scheme.def_id {
                some(id) => id,
                none => return none
            }
            some(h_pattern_binding(HPatternBinding {
                name: name, def_id: def_id,
                slot: make_source_slot_ref(
                    current_identity_file_key(ctx),
                    slot_domain_lexical(), def_id),
                ty: apply_subst(subst, scheme.ty)
            }))
        },
        Pattern::TuplePattern { elements, .. } => {
            let type_elements = match resolved {
                Type::TupleType { elements: values } => values,
                _ => return none
            }
            if elements.len() != type_elements.len() { return none }
            let mut plans: List<HPatternPlan> = []
            let mut index = 0
            while index < elements.len() {
                match exact_pattern_plan(
                        ctx, elements.get(index).unwrap(),
                        type_elements.get(index).unwrap(), subst) {
                    some(plan) => plans.push(plan),
                    none => return none
                }
                index = index + 1
            }
            some(h_pattern_tuple(plans))
        },
        Pattern::Constructor { name, fields, .. } => {
            let enum_name = match resolved {
                Type::EnumType { name: value, .. } => value,
                _ => return none
            }
            let enum_def = match ctx.env.types.enums.get(enum_name) {
                some(value) => value,
                none => return none
            }
            let variant_index = match enum_def.variant_index.get(name) {
                some(value) => value,
                none => return none
            }
            let variant = match enum_def.variants.get(variant_index) {
                some(value) => value,
                none => return none
            }
            let variant_ref = match enum_def.variant_refs.get(variant_index) {
                some(value) => value,
                none => return none
            }
            let field_refs = match enum_def.variant_field_refs.get(variant_index) {
                some(value) => value,
                none => return none
            }
            if fields.len() != variant.fields.len() ||
               fields.len() != field_refs.len() { return none }
            let inst_map = build_instantiation_map(
                enum_def.type_param_vars, resolved)
            let mut plans: List<HPatternFieldPlan> = []
            let mut index = 0
            while index < fields.len() {
                let child = match exact_pattern_plan(
                        ctx, fields.get(index).unwrap(),
                        apply_subst_map(
                            inst_map, variant.fields.get(index).unwrap()),
                        subst) {
                    some(value) => value,
                    none => return none
                }
                plans.push(make_h_pattern_field_plan(
                    h_variant_projection(field_refs.get(index).unwrap()),
                    child))
                index = index + 1
            }
            some(h_pattern_variant(variant_ref, plans))
        },
        Pattern::NamedConstructor { name, fields, .. } => match resolved {
            Type::EnumType { name: enum_name, .. } => {
                let enum_def = match ctx.env.types.enums.get(enum_name) {
                    some(value) => value,
                    none => return none
                }
                let variant_index = match enum_def.variant_index.get(name) {
                    some(value) => value,
                    none => return none
                }
                let variant = match enum_def.variants.get(variant_index) {
                    some(value) => value,
                    none => return none
                }
                let variant_ref = match enum_def.variant_refs.get(variant_index) {
                    some(value) => value,
                    none => return none
                }
                let field_refs = match enum_def.variant_field_refs.get(variant_index) {
                    some(value) => value,
                    none => return none
                }
                let names = match variant.field_names {
                    some(values) => values,
                    none => return none
                }
                let inst_map = build_instantiation_map(
                    enum_def.type_param_vars, resolved)
                let mut plans: List<HPatternFieldPlan> = []
                for field in fields {
                    let index = match names.index_of(field.name) {
                        some(value) => value,
                        none => return none
                    }
                    let child_type = match variant.fields.get(index) {
                        some(value) => value,
                        none => return none
                    }
                    let field_ref = match field_refs.get(index) {
                        some(value) => value,
                        none => return none
                    }
                    let child = match exact_pattern_plan(
                            ctx, field.pattern,
                            apply_subst_map(inst_map, child_type), subst) {
                        some(value) => value,
                        none => return none
                    }
                    plans.push(make_h_pattern_field_plan(
                        h_variant_projection(field_ref), child))
                }
                some(h_pattern_variant(variant_ref, plans))
            },
            Type::StructType { name: struct_name, .. } => {
                let struct_def = match ctx.env.types.structs.get(struct_name) {
                    some(value) => value,
                    none => return none
                }
                let inst_map = build_instantiation_map(
                    struct_def.type_param_vars, resolved)
                let mut plans: List<HPatternFieldPlan> = []
                for field in fields {
                    let exact = match struct_def.fields.find(fn(item) {
                        item.name == field.name
                    }) {
                        some(value) => value,
                        none => return none
                    }
                    let child = match exact_pattern_plan(
                            ctx, field.pattern,
                            apply_subst_map(inst_map, exact.ty), subst) {
                        some(value) => value,
                        none => return none
                    }
                    plans.push(make_h_pattern_field_plan(
                        h_nominal_projection(exact.field_ref),
                        child))
                }
                some(h_pattern_struct(struct_def.owner_ref, plans))
            },
            _ => none
        },
        Pattern::OrPattern { patterns, .. } => {
            let mut plans: List<HPatternPlan> = []
            for alternative in patterns {
                match exact_pattern_plan(ctx, alternative, resolved, subst) {
                    some(plan) => plans.push(plan),
                    none => return none
                }
            }
            if plans.len() < 2 { none } else { some(h_pattern_or(plans)) }
        }
    }
}

fn bind_constructor_pattern(
    ctx: InferCtx, name: Str, qualifier: Str?, fields: List<Pattern>,
    expected_type: Type, subst: UnionFind, span: Span
) -> UnionFind {
    let mut s = subst
    let resolved_expected = apply_subst(s, expected_type)
    match resolved_expected {
        Type::ErrorType => {
            for field in fields {
                bind_pattern_recovery(ctx, field)
            }
            return s
        },
        _ => {}
    }
    let enum_name = resolve_pattern_enum(ctx, name, qualifier, span)
    match enum_name {
        some(ename) => match ctx.env.types.enums.get(ename) {
            some(enum_def) => {
                let variant = lookup_variant(enum_def, name)
                match variant {
                    some(v) => {
                        match resolved_expected {
                            Type::EnumType { name: rname, .. } => {
                                if rname != ename {
                                    let enum_display = nominal_display_name(ename)
                                    let expected_display = nominal_display_name(rname)
                                    let _ = type_error(ctx.sink, E0301,
                                        "variant '${name}' belongs to enum '${enum_display}', not '${expected_display}'",
                                        span, DiagnosticContext::TypeMismatch { expected: expected_display, actual: enum_display, expression: none })
                                    for field in fields {
                                        bind_pattern_recovery(ctx, field)
                                    }
                                    return s
                                }
                            },
                            Type::TypeVar { .. } => {},
                            _ => {
                                let _ = type_error(ctx.sink, E0301,
                                    "cannot destructure type '${type_to_string(resolved_expected)}' with constructor pattern '${name}'",
                                    span, DiagnosticContext::PatternError { detail: "constructor pattern on non-enum type" })
                                for field in fields {
                                    bind_pattern_recovery(ctx, field)
                                }
                                return s
                            }
                        }
                        let inst_map = build_instantiation_map(enum_def.type_param_vars, resolved_expected)
                        if fields.len() != v.fields.len() {
                            let _ = type_error(ctx.sink, E0301,
                                "constructor '${name}' has ${v.fields.len().to_str()} field(s) but pattern has ${fields.len().to_str()}",
                                span, DiagnosticContext::OtherContext { detail: some("constructor arity mismatch") })
                        }
                        let mut i = 0
                        while i < fields.len() {
                            match (fields.get(i), v.fields.get(i)) {
                                (some(fpat), some(ftype)) => {
                                    let variant_index = enum_def.variant_index.get(
                                        name).unwrap()
                                    let field_type = instantiate_enum_field_header(
                                        ctx.env, enum_def, variant_index, i, ftype)
                                    let field_type = if inst_map.len() > 0 {
                                        apply_subst_map(inst_map, field_type)
                                    } else { field_type }
                                    s = bind_pattern(ctx, fpat, field_type, s)
                                },
                                (some(fpat), none) => {
                                    bind_pattern_recovery(ctx, fpat)
                                },
                                _ => {}
                            }
                            i = i + 1
                        }
                    },
                    none => {
                        for field in fields {
                            bind_pattern_recovery(ctx, field)
                        }
                    }
                }
            },
            none => {
                for field in fields {
                    bind_pattern_recovery(ctx, field)
                }
            }
        },
        none => {
            for field in fields {
                bind_pattern_recovery(ctx, field)
            }
        }
    }
    s
}

fn bind_named_constructor_pattern(
    ctx: InferCtx, name: Str, qualifier: Str?, fields: List<NamedPatternField>,
    expected_type: Type, subst: UnionFind, span: Span
) -> UnionFind {
    let mut s = subst
    let resolved_expected = apply_subst(s, expected_type)
    match resolved_expected {
        Type::ErrorType => {
            bind_named_pattern_fields_recovery(ctx, fields)
            return s
        },
        _ => {}
    }
    // Resolve relative paths (self::/super::) to actual qualified names
    let mut resolved_qualifier = qualifier
    match qualifier {
        some(q) => {
            if q == "self" || q.starts_with("super") {
                match resolve_relative_qualifier(q, ctx.mod_path_stack) {
                    some(prefix) => {
                        if prefix == "" {
                            resolved_qualifier = none
                        } else {
                            resolved_qualifier = some(prefix)
                        }
                    },
                    none => {
                        let _ = type_error(ctx.sink, E0705,
                            "Cannot use '${q}' — relative path exceeds module nesting depth",
                            span, DiagnosticContext::OtherContext { detail: some("relative path out of scope") })
                        bind_named_pattern_fields_recovery(ctx, fields)
                        return s
                    }
                }
            }
        },
        none => {}
    }

    // Try enum variant lookup first (non-error-reporting)
    let enum_name = try_resolve_pattern_enum(ctx, name, resolved_qualifier)
    match enum_name {
        some(ename) => match ctx.env.types.enums.get(ename) {
            some(enum_def) => {
                let variant = lookup_variant(enum_def, name)
                match variant {
                    some(v) => match v.field_names {
                        some(vfield_names) => {
                            match resolved_expected {
                                Type::EnumType { name: rname, .. } => {
                                    if rname != ename {
                                        let enum_display = nominal_display_name(ename)
                                        let expected_display = nominal_display_name(rname)
                                        let _ = type_error(ctx.sink, E0301,
                                            "variant '${name}' belongs to enum '${enum_display}', not '${expected_display}'",
                                            span, DiagnosticContext::TypeMismatch { expected: expected_display, actual: enum_display, expression: none })
                                        bind_named_pattern_fields_recovery(ctx, fields)
                                        return s
                                    }
                                },
                                Type::TypeVar { .. } => {},
                                _ => {
                                    bind_named_pattern_fields_recovery(ctx, fields)
                                    return s
                                }
                            }
                            let inst_map = build_instantiation_map(enum_def.type_param_vars, resolved_expected)
                            for field in fields {
                                let field_idx = vfield_names.index_of(field.name)
                                match field_idx {
                                    some(idx) => match v.fields.get(idx) {
                                        some(ftype) => {
                                            let variant_index = enum_def.variant_index.get(
                                                name).unwrap()
                                            let field_type = instantiate_enum_field_header(
                                                ctx.env, enum_def,
                                                variant_index, idx, ftype)
                                            let field_type = if inst_map.len() > 0 {
                                                apply_subst_map(
                                                    inst_map, field_type)
                                            } else { field_type }
                                            s = bind_pattern(ctx, field.pattern, field_type, s)
                                        },
                                        none => {
                                            bind_pattern_recovery(ctx, field.pattern)
                                        }
                                    },
                                    none => {
                                        let _ = type_error(ctx.sink, E0301,
                                            "variant '${name}' has no field '${field.name}'",
                                            field.span, DiagnosticContext::OtherContext { detail: some("unknown field '${field.name}'") })
                                        bind_pattern_recovery(ctx, field.pattern)
                                    }
                                }
                            }
                        },
                        none => {
                            let _ = type_error(ctx.sink, E0301,
                                "variant '${name}' uses positional fields and cannot be matched with named fields",
                                span, DiagnosticContext::PatternError { detail: "named pattern on positional variant" })
                            bind_named_pattern_fields_recovery(ctx, fields)
                        }
                    },
                    none => {
                        bind_named_pattern_fields_recovery(ctx, fields)
                    }
                }
            },
            none => {
                bind_named_pattern_fields_recovery(ctx, fields)
            }
        },
        none => {
            // Not an enum variant — try struct lookup
            let struct_name = match resolved_qualifier {
                some(q) => "${q}::${name}",
                none => name
            }
            s = bind_struct_pattern_fields(ctx, struct_name, name, fields, expected_type, s, span)
        }
    }
    s
}

fn bind_struct_pattern_fields(
    ctx: InferCtx, struct_name: Str, display_name: Str, fields: List<NamedPatternField>,
    expected_type: Type, subst: UnionFind, span: Span
) -> UnionFind {
    let mut s = subst
    let resolved_expected = apply_subst(s, expected_type)
    match resolved_expected {
        Type::ErrorType => {
            bind_named_pattern_fields_recovery(ctx, fields)
            return s
        },
        _ => {}
    }
    match ctx.env.types.structs.get(struct_name) {
        some(struct_def) => {
            match resolved_expected {
                Type::StructType { name: expected_name, .. } => {
                    if expected_name != struct_def.name {
                        bind_named_pattern_fields_recovery(ctx, fields)
                        return s
                    }
                },
                Type::TypeVar { .. } => {},
                _ => {
                    bind_named_pattern_fields_recovery(ctx, fields)
                    return s
                }
            }
            let inst_map = build_instantiation_map(struct_def.type_param_vars, resolved_expected)
            for field in fields {
                let found = struct_def.fields.find(fn(sf) { sf.name == field.name })
                match found {
                    some(sf) => {
                        let field_type = instantiate_struct_field_header(
                            ctx.env, struct_def, sf)
                        let field_type = if inst_map.len() > 0 {
                            apply_subst_map(inst_map, field_type)
                        } else { field_type }
                        s = bind_pattern(ctx, field.pattern, field_type, s)
                    },
                    none => {
                        let _ = type_error(ctx.sink, E0301,
                            "struct '${display_name}' has no field '${field.name}'",
                            field.span, DiagnosticContext::OtherContext { detail: some("unknown field '${field.name}'") })
                        bind_pattern_recovery(ctx, field.pattern)
                    }
                }
            }
        },
        none => {
            // Try with mod path prefix
            if ctx.mod_path_stack.len() > 0 {
                let mod_prefix = ctx.mod_path_stack.join("::")
                let full_name = "${mod_prefix}::${struct_name}"
                match ctx.env.types.structs.get(full_name) {
                    some(sdef) => {
                        match resolved_expected {
                            Type::StructType { name: expected_name, .. } => {
                                if expected_name != sdef.name {
                                    bind_named_pattern_fields_recovery(ctx, fields)
                                    return s
                                }
                            },
                            Type::TypeVar { .. } => {},
                            _ => {
                                bind_named_pattern_fields_recovery(ctx, fields)
                                return s
                            }
                        }
                        let inst_map = build_instantiation_map(sdef.type_param_vars, resolved_expected)
                        for field in fields {
                            let found = sdef.fields.find(fn(sf) { sf.name == field.name })
                            match found {
                                some(sf) => {
                                    let field_type = instantiate_struct_field_header(
                                        ctx.env, sdef, sf)
                                    let field_type = if inst_map.len() > 0 {
                                        apply_subst_map(
                                            inst_map, field_type)
                                    } else { field_type }
                                    s = bind_pattern(ctx, field.pattern, field_type, s)
                                },
                                none => {
                                    bind_pattern_recovery(ctx, field.pattern)
                                }
                            }
                        }
                    },
                    none => {
                        bind_named_pattern_fields_recovery(ctx, fields)
                    }
                }
            } else {
                bind_named_pattern_fields_recovery(ctx, fields)
            }
        }
    }
    s
}

// Like resolve_pattern_enum but returns none silently if not found (no E0201 error).
// Used by bind_named_constructor_pattern where the name might be a struct, not an enum variant.
fn try_resolve_pattern_enum(ctx: InferCtx, variant_name: Str, qualifier: Str?) -> Str? {
    match qualifier {
        some(q) => {
            let direct = ctx.env.types.enums.get(q)
            match direct {
                some(enum_def) => {
                    if enum_def.variant_index.contains_key(variant_name) {
                        return some(enum_def.name)
                    }
                    return none
                },
                none => {}
            }
            if ctx.mod_path_stack.len() > 0 {
                let mod_prefix = ctx.mod_path_stack.join("::")
                let full_q = "${mod_prefix}::${q}"
                let fallback = ctx.env.types.enums.get(full_q)
                match fallback {
                    some(enum_def2) => {
                        if enum_def2.variant_index.contains_key(variant_name) {
                            return some(enum_def2.name)
                        }
                    },
                    none => {}
                }
            }
            none
        },
        none => ctx.env.types.variant_to_enum.get(variant_name)
    }
}

fn resolve_pattern_enum(ctx: InferCtx, variant_name: Str, qualifier: Str?, span: Span) -> Str? {
    match qualifier {
        some(q) => {
            // Try direct qualifier first
            let direct = ctx.env.types.enums.get(q)
            match direct {
                some(enum_def) => {
                    if enum_def.variant_index.contains_key(variant_name) {
                        return some(enum_def.name)
                    }
                    let qualifier_display = nominal_display_name(q)
                    let _ = type_error(ctx.sink, E0201,
                        "'${qualifier_display}' has no variant '${variant_name}'",
                        span, DiagnosticContext::UndefinedVariable { name: variant_name, scope_locals: none })
                    return none
                },
                none => {}
            }
            // Fallback: try prepending current mod path
            if ctx.mod_path_stack.len() > 0 {
                let mod_prefix = ctx.mod_path_stack.join("::")
                let full_q = "${mod_prefix}::${q}"
                let fallback = ctx.env.types.enums.get(full_q)
                match fallback {
                    some(enum_def2) => {
                        if enum_def2.variant_index.contains_key(variant_name) {
                            return some(enum_def2.name)
                        }
                    },
                    none => {}
                }
            }
            let qualifier_display = nominal_display_name(q)
            let _ = type_error(ctx.sink, E0201,
                "'${qualifier_display}' has no variant '${variant_name}'",
                span, DiagnosticContext::UndefinedVariable { name: variant_name, scope_locals: none })
            none
        },
        none => ctx.env.types.variant_to_enum.get(variant_name)
    }
}

fn build_instantiation_map(type_param_vars: List<Int>, resolved_expected: Type) -> Map<Int, Type> {
    let mut inst_map: Map<Int, Type> = map_new()
    match resolved_expected {
        Type::EnumType { type_params, .. } => {
            let mut i = 0
            while i < type_param_vars.len() && i < type_params.len() {
                match (type_param_vars.get(i), type_params.get(i)) {
                    (some(var_id), some(tp)) => { inst_map.insert(var_id, tp) },
                    _ => {}
                }
                i = i + 1
            }
        },
        Type::StructType { type_params, .. } => {
            let mut i = 0
            while i < type_param_vars.len() && i < type_params.len() {
                match (type_param_vars.get(i), type_params.get(i)) {
                    (some(var_id), some(tp)) => { inst_map.insert(var_id, tp) },
                    _ => {}
                }
                i = i + 1
            }
        },
        _ => {}
    }
    inst_map
}

// ============================================================
// Effect removal helpers
// ============================================================

pub fn remove_fail_effect(row: EffectRow) -> EffectRow {
    let filtered = row.effects.filter(fn(e) {
        match e { Effect::FailEffect { .. } => false, _ => true }
    })
    EffectRow { effects: filtered, tail: row.tail }
}

// ============================================================
// Relative path resolution (self::/super::)
// ============================================================

// Resolves a qualifier containing "self"/"super" relative path
// segments against the current mod_path_stack.
// Returns the resolved fully-qualified prefix, or none on error.
pub fn resolve_relative_qualifier(qualifier: Str, mod_path_stack: List<Str>) -> Str? {
    if qualifier == "self" {
        if mod_path_stack.len() == 0 {
            return none
        }
        return some(mod_path_stack.join("::"))
    }
    // Handle "super" and "super::super" etc.
    let parts = qualifier.split("::")
    let mut super_count = 0
    for part in parts {
        if part == "super" {
            super_count = super_count + 1
        } else {
            break
        }
    }
    if super_count == 0 {
        return none
    }
    if super_count > mod_path_stack.len() {
        return none
    }
    // Build resolved prefix from mod_path_stack[0..len-super_count]
    let remaining = mod_path_stack.len() - super_count
    let mut resolved_parts: List<Str> = []
    let mut i = 0
    while i < remaining {
        resolved_parts.push(mod_path_stack.get(i).unwrap_or(""))
        i = i + 1
    }
    // Append any non-super trailing parts from qualifier
    let mut j = super_count
    while j < parts.len() {
        resolved_parts.push(parts.get(j).unwrap_or(""))
        j = j + 1
    }
    if resolved_parts.len() == 0 {
        return some("")
    }
    some(resolved_parts.join("::"))
}

// Bind every namespace carried by an inline relative import. Values, nominal
// types, aliases, effects and traits deliberately have independent tables; a
// type-only `pub use self/super::...` must not be rejected merely because the
// value environment has no entry with that spelling. This resolver is shared
// by registration and checking so imported names are available in declaration
// signatures as well as bodies, under exactly the same canonical identities.
fn import_identity_leaf(identity: Str) -> Str {
    let inline_parts = identity.split("::")
    let inline_leaf = inline_parts.get(inline_parts.len() - 1).unwrap_or(identity)
    let file_parts = inline_leaf.split("$$_")
    file_parts.get(file_parts.len() - 1).unwrap_or(inline_leaf)
}

fn canonical_relative_prefix(ctx: InferCtx, resolved_prefix: Str) -> Str {
    if ctx.mod_path_stack.len() == 0 { return resolved_prefix }
    let first = ctx.mod_path_stack.get(0).unwrap_or("")
    let root_parts = first.split("$$_")
    if root_parts.len() < 2 { return resolved_prefix }
    if resolved_prefix.index_of("$$_").is_some() { return resolved_prefix }
    let root = "${root_parts.get(0).unwrap_or("")}$$_"
    if resolved_prefix == "" { root } else { "${root}${resolved_prefix}" }
}

fn append_import_identity(prefix: Str, name: Str) -> Str {
    if prefix == "" { name }
    else if prefix.ends_with("$$_") { "${prefix}${name}" }
    else { "${prefix}::${name}" }
}

// Copy one already-resolved source key to one alias key across every namespace.
// Value metadata is snapshotted before bind allocates a new DefId, and its
// origin is flattened immediately to the final declaration identity.
pub fn bind_exact_import_alias(
    mut ctx: InferCtx, alias_name: Str, source_identity: Str, include_values: Bool
) -> Bool {
    let mut found = false
    if include_values {
        match ctx.env.lookup(source_identity) {
            some(scheme) => {
                let exact_origin = exact_scheme_value_origin(
                    ctx.use_aliases, scheme, source_identity)
                // The source key may itself be a stale re-export alias created
                // before an inferred function was checked. Prefer the flattened
                // declaration's live scheme when it is already rebound; the
                // canonical rebind scan handles the opposite ordering where
                // this fresh alias exists first.
                let live_scheme = match ctx.env.lookup(exact_origin) {
                    some(origin_scheme) => origin_scheme,
                    none => scheme
                }
                let source_kind = value_binding_kind(ctx, scheme.def_id)
                let ctor_origin = variant_ctor_origin(ctx, scheme)
                let mut_flags = match ctx.fn_mut_params.get(source_identity) {
                    some(flags) => some(flags),
                    none => ctx.fn_mut_params.get(exact_origin)
                }
                if alias_name != source_identity {
                    ctx.env.bind(alias_name, TypeScheme {
                        ty: live_scheme.ty,
                        type_vars: live_scheme.type_vars,
                        bounds: live_scheme.bounds,
                        effect_schema: live_scheme.effect_schema,
                        def_id: none
                    })
                    record_value_origin(ctx, alias_name, exact_origin)
                    match source_kind {
                        ValueBindingKind::DirectCallable =>
                            record_value_binding_kind(ctx, alias_name, source_kind),
                        ValueBindingKind::ExternCallable =>
                            record_value_binding_kind(ctx, alias_name, source_kind),
                        ValueBindingKind::ConstGetter =>
                            record_value_binding_kind(ctx, alias_name, source_kind),
                        ValueBindingKind::LocalBorrow => {}
                    }
                    match ctor_origin {
                        some(origin) => {
                            record_variant_ctor_origin(ctx, alias_name, origin)
                        },
                        none => {}
                    }
                    match mut_flags {
                        some(flags) => { ctx.fn_mut_params.insert(alias_name, flags) },
                        none => {}
                    }
                }
                found = true
            },
            none => {}
        }
    }
    match ctx.env.types.structs.get(source_identity) {
        some(def) => {
            if alias_name != source_identity {
                ctx.env.types.structs.insert(alias_name, def)
            }
            found = true
        },
        none => {}
    }
    match ctx.env.types.enums.get(source_identity) {
        some(def) => {
            if alias_name != source_identity {
                ctx.env.types.enums.insert(alias_name, def)
            }
            found = true
        },
        none => {}
    }
    match ctx.env.types.type_aliases.get(source_identity) {
        some(def) => {
            if alias_name != source_identity {
                ctx.env.types.type_aliases.insert(alias_name, def)
            }
            found = true
        },
        none => {}
    }
    match ctx.env.types.effects.get(source_identity) {
        some(def) => {
            if alias_name != source_identity {
                ctx.env.types.effects.insert(alias_name, def)
            }
            found = true
        },
        none => {}
    }
    match ctx.env.types.effect_aliases.get(source_identity) {
        some(def) => {
            if alias_name != source_identity {
                ctx.env.types.effect_aliases.insert(alias_name, def)
            }
            found = true
        },
        none => {}
    }
    match ctx.env.trait_reg.traits.get(source_identity) {
        some(def) => {
            if alias_name != source_identity {
                ctx.env.trait_reg.traits.insert(alias_name, def)
            }
            found = true
        },
        none => {}
    }
    found
}

fn impl_assoc_constraints_match_fn_bound(
    constraints: List<ImplAssocPredicate>, bound: FnBoundsEntry,
    var_map: Map<Int, Type>, s: UnionFind
) -> Bool {
    for expected in constraints {
        let expected_ty = apply_subst(s, apply_subst_map(
            var_map, impl_assoc_predicate_type(expected)))
        let mut matched = false
        for actual in bound.assoc_constraints {
            if actual.name == impl_assoc_predicate_name(expected) {
                matched = true
                if !types_equal(expected_ty, apply_subst(s, actual.ty)) {
                    return false
                }
            }
        }
        if !matched { return false }
    }
    true
}

fn impl_assoc_constraints_match_concrete(
    env: TypeEnv, subject: Type, trait_name: Str,
    constraints: List<ImplAssocPredicate>,
    var_map: Map<Int, Type>, s: UnionFind
) -> Bool {
    if constraints.len() == 0 { return true }
    let concrete = apply_subst(s, subject)
    let mut target_name: Str? = none
    let mut type_args: List<Type> = []
    match concrete {
        Type::StructType { name, type_params } => {
            target_name = some(name)
            type_args = type_params
        },
        Type::EnumType { name, type_params } => {
            target_name = some(name)
            type_args = type_params
        },
        _ => match type_to_builtin_name(concrete) {
            some(name) => { target_name = some(name) },
            none => return false
        }
    }
    let target = match target_name {
        some(name) => name,
        none => return false
    }
    let entry = match find_impl(env.trait_reg, target, trait_name) {
        some(found) => found,
        none => return false
    }
    if entry.type_param_vars.len() != type_args.len() { return false }
    let mut owner_map: Map<Int, Type> = map_new()
    for index in 0..entry.type_param_vars.len() {
        match (entry.type_param_vars.get(index), type_args.get(index)) {
            (some(source), some(actual)) => owner_map.insert(source, actual),
            _ => return false
        }
    }
    for expected in constraints {
        match entry.assoc_types.get(impl_assoc_predicate_name(expected)) {
            some(actual) => {
                let expected_ty = apply_subst(s, apply_subst_map(
                    var_map, impl_assoc_predicate_type(expected)))
                let actual_ty = apply_subst(s, apply_subst_map(
                    owner_map, instantiate_impl_assoc_header(
                        env, entry,
                        impl_assoc_predicate_name(expected), actual)))
                if !types_equal(expected_ty, actual_ty) { return false }
            },
            none => return false
        }
    }
    true
}

fn find_matching_fn_bound(
    current_fn_bounds: List<FnBoundsEntry>, subject: Type,
    s: UnionFind, trait_name: Str
) -> FnBoundsEntry? {
    match apply_subst(s, subject) {
        Type::TypeVar { id, .. } => current_fn_bounds.find(fn(bound) {
            if bound.trait_name != trait_name { false } else {
                let resolved = apply_subst(s, Type::TypeVar {
                    id: bound.type_param_var_id, name: none
                })
                match resolved {
                    Type::TypeVar { id: resolved_id, .. } =>
                        resolved_id == id || bound.type_param_var_id == id ||
                            uf_find(s, bound.type_param_var_id) == id,
                    _ => false
                }
            }
        }),
        _ => none
    }
}

pub fn impl_predicate_constraints_satisfied(
    env: TypeEnv, current_fn_bounds: List<FnBoundsEntry>,
    subject: Type, trait_name: Str,
    constraints: List<ImplAssocPredicate>, s: UnionFind
) -> Bool {
    match find_matching_fn_bound(
        current_fn_bounds, subject, s, trait_name
    ) {
        some(bound) => impl_assoc_constraints_match_fn_bound(
            constraints, bound, map_new(), s),
        none => impl_assoc_constraints_match_concrete(
            env, subject, trait_name, constraints, map_new(), s)
    }
}

fn prove_named_dict_evidence(
    env: TypeEnv, current_fn_bounds: List<FnBoundsEntry>,
    name: Str, type_params: List<Type>, s: UnionFind, trait_name: Str
) -> Bool {
    let impl_entry = match find_impl(env.trait_reg, name, trait_name) {
        some(value) => value,
        none => return false
    }
    let requirements = match instantiate_impl_runtime_requirements(
            impl_entry, type_params) {
        some(value) => value,
        none => return false
    }
    for requirement in requirements {
        if !prove_dict_evidence_for_type(
                env, current_fn_bounds, requirement.subject_type, s,
                requirement.canonical_trait_name) {
            return false
        }
        let assoc_valid = match find_matching_fn_bound(
                current_fn_bounds, requirement.subject_type, s,
                requirement.canonical_trait_name) {
            some(bound) => impl_assoc_constraints_match_fn_bound(
                requirement.assoc_constraints, bound, map_new(), s),
            none => impl_assoc_constraints_match_concrete(
                env, requirement.subject_type,
                requirement.canonical_trait_name,
                requirement.assoc_constraints, map_new(), s)
        }
        if !assoc_valid { return false }
    }
    true
}

pub fn prove_dict_evidence_for_type(
    env: TypeEnv, current_fn_bounds: List<FnBoundsEntry>,
    source: Type, s: UnionFind, trait_name: Str
) -> Bool {
    match apply_subst(s, source) {
        Type::TypeVar { .. } => find_matching_fn_bound(
            current_fn_bounds, source, s, trait_name).is_some(),
        Type::StructType { name, type_params } |
        Type::EnumType { name, type_params } => prove_named_dict_evidence(
            env, current_fn_bounds, name, type_params, s, trait_name),
        Type::ErrorType => false,
        concrete => match type_to_builtin_name(concrete) {
            some(name) => find_impl(env.trait_reg, name, trait_name).is_some(),
            none => false
        }
    }
}

fn resolve_impl_owner_evidence(
    runtime_owner: ExecutableRef,
    sink: CollectingSink, env: TypeEnv,
    current_fn_bounds: List<FnBoundsEntry>,
    owner: ImplEntry, core: ImplMethodSchemeCore,
    callee_type: Type, s: UnionFind, span: Span,
    report_assoc_mismatch: Bool
) -> SchemeEvidenceResolution {
    let predicates = frozen_impl_predicates(owner.predicates)
    if predicates.len() == 0 {
        return SchemeEvidenceResolution::Resolved {
            dicts: [], assoc_mismatch: false
        }
    }
    let core_scheme = impl_method_core_as_scheme(core)
    let var_map = build_scheme_var_map(core_scheme, callee_type)
    let mut resolved_dicts: List<DictRef> = []
    let mut pending_failures: List<EvidenceFailure> = []
    let mut missing_failures: List<EvidenceFailure> = []
    let mut assoc_mismatch = false
    for predicate in predicates {
        let trait_name = impl_predicate_trait_name(predicate)
        match var_map.get(impl_predicate_subject_type_var(predicate)) {
            some(subject) => {
                match resolve_dict_evidence_for_type(
                    runtime_owner, env, current_fn_bounds,
                    subject, s, trait_name
                ) {
                    DictEvidenceResolution::Resolved { dict_ref } => {
                        let constraints = impl_predicate_assoc_constraints(
                            predicate)
                        let assoc_valid = match find_matching_fn_bound(
                            current_fn_bounds, subject, s, trait_name
                        ) {
                            some(bound) => impl_assoc_constraints_match_fn_bound(
                                constraints, bound, var_map, s),
                            none => impl_assoc_constraints_match_concrete(
                                env, subject, trait_name,
                                constraints, var_map, s)
                        }
                        if assoc_valid {
                            resolved_dicts.push(dict_ref)
                        } else {
                            assoc_mismatch = true
                            if report_assoc_mismatch {
                                let _ = type_error(sink, E0513,
                                    "Associated type constraint mismatch for impl predicate '${nominal_display_name(trait_name)}'",
                                    span, DiagnosticContext::TraitError {
                                        detail: "impl-owner associated predicate mismatch"
                                    })
                            }
                        }
                    },
                    DictEvidenceResolution::Pending =>
                        pending_failures.push(EvidenceFailure {
                            trait_name: trait_name,
                            suppress_diagnostic: false
                        }),
                    DictEvidenceResolution::Missing { suppress_diagnostic } =>
                        missing_failures.push(EvidenceFailure {
                            trait_name: trait_name,
                            suppress_diagnostic: suppress_diagnostic
                        })
                }
            },
            none => missing_failures.push(EvidenceFailure {
                trait_name: trait_name,
                suppress_diagnostic: false
            })
        }
    }
    if missing_failures.len() > 0 {
        SchemeEvidenceResolution::Missing { failures: missing_failures }
    } else if pending_failures.len() > 0 {
        SchemeEvidenceResolution::Pending { failures: pending_failures }
    } else {
        SchemeEvidenceResolution::Resolved {
            dicts: resolved_dicts, assoc_mismatch: assoc_mismatch
        }
    }
}

fn resolve_pending_evidence_source(
    runtime_owner: ExecutableRef,
    sink: CollectingSink, env: TypeEnv,
    fn_bounds: List<FnBoundsEntry>, source: PendingEvidenceSource,
    callee_type: Type, s: UnionFind, span: Span,
    report_assoc_mismatch: Bool
) -> SchemeEvidenceResolution {
    match source {
        PendingEvidenceSource::SchemeEvidenceSource(scheme) =>
            resolve_scheme_evidence(
                runtime_owner, sink, env, fn_bounds,
                scheme, callee_type, s, span,
                report_assoc_mismatch),
        PendingEvidenceSource::ImplOwnerEvidenceSource {
            owner, method_core
        } => resolve_impl_owner_evidence(
            runtime_owner, sink, env, fn_bounds, owner, method_core,
            callee_type, s, span, report_assoc_mismatch)
    }
}

pub fn install_struct_identity_ledger(
    mut ctx: InferCtx, file_key: Str, plan: ResolvedNamespacePlan
) {
    if ctx.struct_identity_file_key.is_some() ||
       ctx.struct_identity_frame_stack.len() != 0 ||
       ctx.struct_identity_unconsumed.len() != 0 ||
       ctx.struct_identity_pending.len() != 0 ||
       ctx.trait_identity_unconsumed.len() != 0 ||
       ctx.enum_identity_unconsumed.len() != 0 ||
       ctx.effect_identity_unconsumed.len() != 0 ||
       ctx.effect_identity_unconsumed.len() != 0 ||
       ctx.enum_identity_unconsumed.len() != 0 ||
       ctx.source_impl_provider_unconsumed.len() != 0 ||
       ctx.delegate_provider_unconsumed.len() != 0 ||
       ctx.nominal_derived_provider_unconsumed.len() != 0 ||
       ctx.impl_check_frame_stack.len() != 0 {
        panic("struct identity ledger: prior ledger is still active")
    }
    ctx.struct_identity_file_key = some(file_key)
    ctx.struct_identity_root_frame = none
    ctx.struct_identity_child_frames = map_new()
    let retain_registration_bindings =
        ctx.project_namespace_file_key.is_none()
    if retain_registration_bindings {
        // Single-file and prelude checking do not install a project overlay,
        // but registration still consumes the same resolved binding facts.
        ctx.project_namespace_bindings = map_new()
    }
    for binding in plan.bindings {
        if retain_registration_bindings && binding.file_key == file_key {
            match ctx.project_namespace_bindings.get(binding.frame_index) {
                some(existing) => existing.push(binding),
                none => ctx.project_namespace_bindings.insert(
                    binding.frame_index, [binding])
            }
        }
        match binding.namespace {
            NamespaceKind::Value => {
                let payload = symbol_ref_canonical_payload(binding.symbol)
                match ctx.value_symbols_by_payload.get(payload) {
                    some(existing) => if !symbol_ref_same(
                            existing, binding.symbol) {
                        panic("value identity: canonical payload has two SymbolRefs")
                    },
                    none => ctx.value_symbols_by_payload.insert(
                        payload, binding.symbol)
                }
            },
            _ => {}
        }
    }
    // Project dependency hydration precedes installation of this module's
    // resolver plan. Relate those already-minted alias DefIds now that their
    // exact delivered SymbolRefs are available.
    for alias_entry in ctx.use_aliases.entries() {
        let (def_id, payload) = alias_entry
        match ctx.value_symbols_by_payload.get(payload) {
            some(symbol) => ctx.value_symbols.insert(def_id, symbol),
            none => {}
        }
    }
    for frame in plan.frames {
        if frame.file_key == file_key {
            if frame.parent_frame_index < 0 {
                if ctx.struct_identity_root_frame.is_some() {
                    panic("struct identity ledger: duplicate root frame")
                }
                ctx.struct_identity_root_frame = some(frame.frame_index)
                if ctx.impl_check_root_frames.contains_key(file_key) {
                    panic("impl check index: duplicate file root")
                }
                ctx.impl_check_root_frames.insert(file_key, frame.frame_index)
            } else {
                let key = project_child_site_key(
                    frame.parent_frame_index, frame.decl_index)
                if ctx.struct_identity_child_frames.contains_key(key) {
                    panic("struct identity ledger: duplicate child frame")
                }
                ctx.struct_identity_child_frames.insert(key, frame.frame_index)
                let check_key = "${file_key}|${key}"
                if ctx.impl_check_child_frames.contains_key(check_key) {
                    panic("impl check index: duplicate child frame")
                }
                ctx.impl_check_child_frames.insert(
                    check_key, frame.frame_index)
            }
        }
    }
    for fact in plan.struct_identities {
        if fact.file_key == file_key {
            for existing in ctx.struct_identity_unconsumed {
                if existing.frame_index == fact.frame_index &&
                   existing.decl_index == fact.decl_index {
                    panic("struct identity ledger: duplicate declaration site")
                }
            }
            ctx.struct_identity_unconsumed.push(fact)
        }
    }
    for fact in plan.trait_identities {
        if fact.file_key == file_key {
            for existing in ctx.trait_identity_unconsumed {
                if trait_identity_site_same(existing, fact) {
                    panic("trait identity ledger: duplicate declaration site")
                }
            }
            ctx.trait_identity_unconsumed.push(fact)
        }
    }
    for group in plan.enum_variant_facts {
        if symbol_ref_origin_module_key(group.enum_symbol) == file_key {
            for existing in ctx.enum_identity_unconsumed {
                if symbol_ref_same(
                        existing.enum_symbol, group.enum_symbol) {
                    panic("enum identity ledger: duplicate declaration owner")
                }
            }
            ctx.enum_identity_unconsumed.push(group)
        }
    }
    for fact in plan.effect_identities {
        if fact.file_key == file_key {
            for existing in ctx.effect_identity_unconsumed {
                if symbol_ref_same(existing.owner_ref, fact.owner_ref) {
                    panic("effect identity ledger: duplicate declaration owner")
                }
            }
            ctx.effect_identity_unconsumed.push(fact)
        }
    }
    for fact in plan.source_impl_providers {
        if fact.file_key == file_key {
            for existing in ctx.source_impl_provider_unconsumed {
                if existing.frame_index == fact.frame_index &&
                   existing.decl_index == fact.decl_index {
                    panic("impl provider ledger: duplicate source declaration site")
                }
            }
            ctx.source_impl_provider_unconsumed.push(fact)
        }
    }
    for fact in plan.delegate_providers {
        if fact.file_key == file_key {
            for existing in ctx.delegate_provider_unconsumed {
                if existing.frame_index == fact.frame_index &&
                   existing.parent_decl_index == fact.parent_decl_index &&
                   existing.source_member_index == fact.source_member_index {
                    panic("impl provider ledger: duplicate delegate declaration site")
                }
            }
            ctx.delegate_provider_unconsumed.push(fact)
        }
    }
    for fact in plan.nominal_derived_providers {
        if fact.file_key == file_key {
            for existing in ctx.nominal_derived_provider_unconsumed {
                if existing.frame_index == fact.frame_index &&
                   existing.decl_index == fact.decl_index {
                    panic("impl provider ledger: duplicate nominal declaration site")
                }
            }
            ctx.nominal_derived_provider_unconsumed.push(fact)
        }
    }
    if ctx.struct_identity_root_frame.is_none() {
        panic("struct identity ledger: missing root frame")
    }
}

fn trait_identity_site_same(
    left: TraitIdentityFact, right: TraitIdentityFact
) -> Bool {
    left.file_key == right.file_key &&
        left.frame_index == right.frame_index &&
        left.decl_index == right.decl_index
}

pub fn enter_struct_identity_root_frame(mut ctx: InferCtx) {
    if ctx.struct_identity_frame_stack.len() != 0 {
        panic("struct identity ledger: root entered while active")
    }
    match ctx.struct_identity_root_frame {
        some(frame) => ctx.struct_identity_frame_stack.push(frame),
        none => panic("struct identity ledger: missing installed root")
    }
}

pub fn enter_struct_identity_child_frame(mut ctx: InferCtx, decl_index: Int) {
    let parent = match ctx.struct_identity_frame_stack.get(
        ctx.struct_identity_frame_stack.len() - 1) {
        some(frame) => frame,
        none => panic("struct identity ledger: child entered without parent")
    }
    match ctx.struct_identity_child_frames.get(
        project_child_site_key(parent, decl_index)) {
        some(frame) => ctx.struct_identity_frame_stack.push(frame),
        none => panic("struct identity ledger: missing child frame")
    }
}

pub fn exit_struct_identity_frame(mut ctx: InferCtx) {
    if ctx.struct_identity_frame_stack.pop().is_none() {
        panic("struct identity ledger: frame exit underflow")
    }
}

fn struct_identity_fact_same(
    left: StructIdentityFact, right: StructIdentityFact
) -> Bool {
    if left.file_key != right.file_key ||
       left.frame_index != right.frame_index ||
       left.decl_index != right.decl_index ||
       left.is_extern != right.is_extern ||
       !symbol_ref_same(left.owner_ref, right.owner_ref) ||
       left.fields.len() != right.fields.len() {
        return false
    }
    for field_index in 0..left.fields.len() {
        match (left.fields.get(field_index), right.fields.get(field_index)) {
            (some(a), some(b)) => {
                if a.field_index != b.field_index ||
                   !nominal_field_ref_same(a.field_ref, b.field_ref) {
                    return false
                }
            },
            _ => return false
        }
    }
    true
}

pub fn peek_struct_identity_fact(
    ctx: InferCtx, decl_index: Int,
    is_extern: Bool, field_count: Int
) -> StructIdentityFact {
    let frame_index = match ctx.struct_identity_frame_stack.get(
        ctx.struct_identity_frame_stack.len() - 1) {
        some(frame) => frame,
        none => panic("struct identity ledger: declaration outside frame")
    }
    let file_key = ctx.struct_identity_file_key.unwrap_or("")
    let mut found: StructIdentityFact? = none
    for fact in ctx.struct_identity_unconsumed {
        if fact.file_key == file_key && fact.frame_index == frame_index &&
           fact.decl_index == decl_index {
            if found.is_some() {
                panic("struct identity ledger: duplicate consume match")
            }
            found = some(fact)
        }
    }
    let fact = match found {
        some(value) => value,
        none => panic("struct identity ledger: missing declaration fact")
    }
    if fact.is_extern != is_extern || fact.fields.len() != field_count {
        panic("struct identity ledger: declaration shape mismatch")
    }
    fact
}

pub fn commit_struct_identity_fact(
    mut ctx: InferCtx, fact: StructIdentityFact, await_fields: Bool
) {
    if await_fields == fact.is_extern {
        panic("struct identity ledger: invalid completion mode")
    }
    let mut matches = 0
    let mut remaining: List<StructIdentityFact> = []
    for existing in ctx.struct_identity_unconsumed {
        if struct_identity_fact_same(existing, fact) {
            matches = matches + 1
        } else {
            remaining.push(existing)
        }
    }
    if matches != 1 {
        panic("struct identity ledger: commit fact mismatch")
    }
    if await_fields {
        for pending in ctx.struct_identity_pending {
            if symbol_ref_same(pending.owner_ref, fact.owner_ref) {
                panic("struct identity ledger: duplicate pending owner")
            }
        }
    }
    ctx.struct_identity_unconsumed = remaining
    if await_fields { ctx.struct_identity_pending.push(fact) }
}

// Enum declarations and other fieldless normal nominals close at their
// resolver-issued declaration site in one step.  They must never enter the
// struct field-completion queue merely to preserve exact owner identity.
pub fn commit_complete_nominal_identity_fact(
    mut ctx: InferCtx, fact: StructIdentityFact
) {
    if fact.is_extern || fact.fields.len() != 0 {
        panic("nominal identity ledger: direct completion shape is invalid")
    }
    let mut matches = 0
    let mut remaining: List<StructIdentityFact> = []
    for existing in ctx.struct_identity_unconsumed {
        if struct_identity_fact_same(existing, fact) {
            matches = matches + 1
        } else {
            remaining.push(existing)
        }
    }
    if matches != 1 {
        panic("nominal identity ledger: direct completion mismatch")
    }
    ctx.struct_identity_unconsumed = remaining
}

pub fn peek_struct_identity_completion(
    ctx: InferCtx, owner_ref: SymbolRef
) -> StructIdentityFact {
    let mut found: StructIdentityFact? = none
    for fact in ctx.struct_identity_pending {
        if symbol_ref_same(fact.owner_ref, owner_ref) {
            if found.is_some() {
                panic("struct identity ledger: duplicate pending completion")
            }
            found = some(fact)
        }
    }
    match found {
        some(value) => value,
        none => panic("struct identity ledger: missing pending completion")
    }
}

pub fn commit_struct_identity_completion(
    mut ctx: InferCtx, fact: StructIdentityFact
) {
    let mut matches = 0
    let mut remaining: List<StructIdentityFact> = []
    for pending in ctx.struct_identity_pending {
        if struct_identity_fact_same(pending, fact) {
            matches = matches + 1
        } else {
            remaining.push(pending)
        }
    }
    if matches != 1 {
        panic("struct identity ledger: completion commit mismatch")
    }
    ctx.struct_identity_pending = remaining
}

fn trait_identity_fact_same(
    left: TraitIdentityFact, right: TraitIdentityFact
) -> Bool {
    if left.file_key != right.file_key ||
       left.frame_index != right.frame_index ||
       left.decl_index != right.decl_index ||
       !symbol_ref_same(left.owner_ref, right.owner_ref) ||
       left.methods.len() != right.methods.len() ||
       left.assoc_members.len() != right.assoc_members.len() {
        return false
    }
    for method_index in 0..left.methods.len() {
        match (left.methods.get(method_index), right.methods.get(method_index)) {
            (some(a), some(b)) => if !trait_method_ref_same(a, b) {
                return false
            },
            _ => return false
        }
    }
    for assoc_index in 0..left.assoc_members.len() {
        if !symbol_ref_same(
                left.assoc_members.get(assoc_index).unwrap(),
                right.assoc_members.get(assoc_index).unwrap()) {
            return false
        }
    }
    true
}

pub fn peek_trait_identity_fact(
    ctx: InferCtx, decl_index: Int,
    method_count: Int, assoc_count: Int
) -> TraitIdentityFact {
    let frame_index = match ctx.struct_identity_frame_stack.get(
        ctx.struct_identity_frame_stack.len() - 1) {
        some(frame) => frame,
        none => panic("trait identity ledger: declaration outside frame")
    }
    let file_key = ctx.struct_identity_file_key.unwrap_or("")
    let mut found: TraitIdentityFact? = none
    for fact in ctx.trait_identity_unconsumed {
        if fact.file_key == file_key && fact.frame_index == frame_index &&
           fact.decl_index == decl_index {
            if found.is_some() {
                panic("trait identity ledger: duplicate consume match")
            }
            found = some(fact)
        }
    }
    let fact = match found {
        some(value) => value,
        none => panic("trait identity ledger: missing declaration fact")
    }
    if fact.methods.len() != method_count ||
       fact.assoc_members.len() != assoc_count {
        panic("trait identity ledger: declaration shape mismatch")
    }
    fact
}

pub fn commit_trait_identity_fact(
    mut ctx: InferCtx, fact: TraitIdentityFact
) {
    let mut matches = 0
    let mut remaining: List<TraitIdentityFact> = []
    for existing in ctx.trait_identity_unconsumed {
        if trait_identity_fact_same(existing, fact) {
            matches = matches + 1
        } else {
            remaining.push(existing)
        }
    }
    if matches != 1 {
        panic("trait identity ledger: commit fact mismatch")
    }
    ctx.trait_identity_unconsumed = remaining
}

fn enum_identity_group_same(
    left: EnumVariantFactGroup, right: EnumVariantFactGroup
) -> Bool {
    if !symbol_ref_same(left.enum_symbol, right.enum_symbol) ||
       !registered_nominal_ref_same(left.owner_ref, right.owner_ref) ||
       left.variants.len() != right.variants.len() {
        return false
    }
    for variant_index in 0..left.variants.len() {
        let a = left.variants.get(variant_index).unwrap()
        let b = right.variants.get(variant_index).unwrap()
        if !variant_ref_same(a.variant_ref, b.variant_ref) ||
           a.fields.len() != b.fields.len() {
            return false
        }
        for field_index in 0..a.fields.len() {
            if !variant_field_ref_same(
                    a.fields.get(field_index).unwrap(),
                    b.fields.get(field_index).unwrap()) {
                return false
            }
        }
    }
    true
}

pub fn peek_enum_identity_group(
    ctx: InferCtx, owner_ref: SymbolRef,
    variant_field_counts: List<Int>
) -> EnumVariantFactGroup {
    let mut found: EnumVariantFactGroup? = none
    for group in ctx.enum_identity_unconsumed {
        if symbol_ref_same(group.enum_symbol, owner_ref) {
            if found.is_some() {
                panic("enum identity ledger: duplicate consume match")
            }
            found = some(group)
        }
    }
    let group = match found {
        some(value) => value,
        none => panic("enum identity ledger: declaration fact is missing")
    }
    if group.variants.len() != variant_field_counts.len() {
        panic("enum identity ledger: variant census changed")
    }
    for index in 0..variant_field_counts.len() {
        if group.variants.get(index).unwrap().fields.len() !=
           variant_field_counts.get(index).unwrap_or(-1) {
            panic("enum identity ledger: payload field census changed")
        }
    }
    group
}

pub fn commit_enum_identity_group(
    mut ctx: InferCtx, group: EnumVariantFactGroup
) {
    let mut matches = 0
    let mut remaining: List<EnumVariantFactGroup> = []
    for existing in ctx.enum_identity_unconsumed {
        if enum_identity_group_same(existing, group) {
            matches = matches + 1
        } else {
            remaining.push(existing)
        }
    }
    if matches != 1 {
        panic("enum identity ledger: commit mismatch")
    }
    ctx.enum_identity_unconsumed = remaining
}

fn effect_identity_fact_same(
    left: EffectIdentityFact, right: EffectIdentityFact
) -> Bool {
    if left.file_key != right.file_key ||
       left.frame_index != right.frame_index ||
       left.decl_index != right.decl_index ||
       !symbol_ref_same(left.owner_ref, right.owner_ref) ||
       !handled_effect_ref_same(left.handled_ref, right.handled_ref) ||
       left.operations.len() != right.operations.len() {
        return false
    }
    for index in 0..left.operations.len() {
        if !effect_operation_ref_same(
                left.operations.get(index).unwrap(),
                right.operations.get(index).unwrap()) {
            return false
        }
    }
    true
}

pub fn peek_effect_identity_fact(
    ctx: InferCtx, decl_index: Int, op_count: Int
) -> EffectIdentityFact {
    let frame_index = current_provider_identity_frame(ctx)
    let file_key = ctx.struct_identity_file_key.unwrap_or("")
    let mut found: EffectIdentityFact? = none
    for fact in ctx.effect_identity_unconsumed {
        if fact.file_key == file_key && fact.frame_index == frame_index &&
           fact.decl_index == decl_index {
            if found.is_some() {
                panic("effect identity ledger: duplicate consume match")
            }
            found = some(fact)
        }
    }
    let fact = match found {
        some(value) => value,
        none => panic("effect identity ledger: declaration fact is missing")
    }
    if fact.operations.len() != op_count {
        panic("effect identity ledger: operation census changed")
    }
    fact
}

pub fn commit_effect_identity_fact(
    mut ctx: InferCtx, fact: EffectIdentityFact
) {
    let mut matches = 0
    let mut remaining: List<EffectIdentityFact> = []
    for existing in ctx.effect_identity_unconsumed {
        if effect_identity_fact_same(existing, fact) {
            matches = matches + 1
        } else {
            remaining.push(existing)
        }
    }
    if matches != 1 {
        panic("effect identity ledger: commit mismatch")
    }
    ctx.effect_identity_unconsumed = remaining
}

fn current_provider_identity_frame(ctx: InferCtx) -> Int {
    match ctx.struct_identity_frame_stack.get(
        ctx.struct_identity_frame_stack.len() - 1) {
        some(frame) => frame,
        none => panic("impl provider ledger: declaration outside frame")
    }
}

fn impl_check_site_key(
    file_key: Str, frame_index: Int, decl_index: Int
) -> Str {
    "${file_key}|${frame_index}|${decl_index}"
}

pub fn publish_impl_check_owner(
    mut ctx: InferCtx, decl_index: Int, owner_ref: ImplOwnerRef
) {
    let frame_index = current_provider_identity_frame(ctx)
    let file_key = ctx.struct_identity_file_key.unwrap_or("")
    let key = impl_check_site_key(file_key, frame_index, decl_index)
    match ctx.impl_check_owners.get(key) {
        some(existing) => if !impl_owner_ref_same(existing, owner_ref) {
            panic("impl check index: source site changed owner")
        },
        none => ctx.impl_check_owners.insert(key, owner_ref)
    }
}

pub fn enter_impl_check_root_frame(mut ctx: InferCtx, file_key: Str) {
    if ctx.impl_check_frame_stack.len() != 0 {
        panic("impl check index: root entered while active")
    }
    match ctx.impl_check_root_frames.get(file_key) {
        some(frame) => ctx.impl_check_frame_stack.push((file_key, frame)),
        none => panic("impl check index: root frame is missing")
    }
}

pub fn enter_impl_check_child_frame(
    mut ctx: InferCtx, decl_index: Int
) {
    let parent = match ctx.impl_check_frame_stack.get(
        ctx.impl_check_frame_stack.len() - 1) {
        some(frame) => frame,
        none => panic("impl check index: child entered without parent")
    }
    match ctx.impl_check_child_frames.get(
            "${parent.0}|${project_child_site_key(parent.1, decl_index)}") {
        some(frame) => ctx.impl_check_frame_stack.push((parent.0, frame)),
        none => panic("impl check index: child frame is missing")
    }
}

pub fn exit_impl_check_frame(mut ctx: InferCtx) {
    if ctx.impl_check_frame_stack.pop().is_none() {
        panic("impl check index: frame exit underflow")
    }
}

pub fn impl_check_owner(
    ctx: InferCtx, decl_index: Int
) -> ImplOwnerRef {
    let frame = match ctx.impl_check_frame_stack.get(
        ctx.impl_check_frame_stack.len() - 1) {
        some(value) => value,
        none => panic("impl check index: declaration outside frame")
    }
    match ctx.impl_check_owners.get(
            impl_check_site_key(frame.0, frame.1, decl_index)) {
        some(owner) => owner,
        none => panic("impl check index: source owner is missing")
    }
}

fn source_impl_provider_fact_same(
    left: SourceImplProviderFact, right: SourceImplProviderFact
) -> Bool {
    if left.file_key != right.file_key ||
       left.frame_index != right.frame_index ||
       left.decl_index != right.decl_index ||
       !impl_provider_ref_same(left.provider_ref, right.provider_ref) ||
       left.methods.len() != right.methods.len() {
        return false
    }
    for index in 0..left.methods.len() {
        match (left.methods.get(index), right.methods.get(index)) {
            (some(a), some(b)) => if
                a.source_member_index != b.source_member_index ||
                a.callable_slot_index != b.callable_slot_index ||
                a.name != b.name ||
                !symbol_ref_same(a.member_ref, b.member_ref) {
                return false
            },
            _ => return false
        }
    }
    true
}

pub fn peek_source_impl_provider_fact(
    ctx: InferCtx, decl_index: Int
) -> SourceImplProviderFact {
    let frame_index = current_provider_identity_frame(ctx)
    let file_key = ctx.struct_identity_file_key.unwrap_or("")
    let mut found: SourceImplProviderFact? = none
    for fact in ctx.source_impl_provider_unconsumed {
        if fact.file_key == file_key && fact.frame_index == frame_index &&
           fact.decl_index == decl_index {
            if found.is_some() {
                panic("impl provider ledger: duplicate source consume match")
            }
            found = some(fact)
        }
    }
    match found {
        some(fact) => fact,
        none => panic("impl provider ledger: missing source impl fact")
    }
}

pub fn commit_source_impl_provider_fact(
    mut ctx: InferCtx, fact: SourceImplProviderFact
) {
    let mut matches = 0
    let mut remaining: List<SourceImplProviderFact> = []
    for existing in ctx.source_impl_provider_unconsumed {
        if source_impl_provider_fact_same(existing, fact) {
            matches = matches + 1
        } else {
            remaining.push(existing)
        }
    }
    if matches != 1 {
        panic("impl provider ledger: source commit mismatch")
    }
    ctx.source_impl_provider_unconsumed = remaining
}

fn delegate_provider_fact_same(
    left: DelegateProviderFact, right: DelegateProviderFact
) -> Bool {
    left.file_key == right.file_key &&
        left.frame_index == right.frame_index &&
        left.parent_decl_index == right.parent_decl_index &&
        left.source_member_index == right.source_member_index &&
        impl_provider_ref_same(
            left.parent_provider_ref, right.parent_provider_ref) &&
        impl_provider_ref_same(left.provider_ref, right.provider_ref)
}

pub fn peek_delegate_provider_fact(
    ctx: InferCtx, parent_decl_index: Int, source_member_index: Int
) -> DelegateProviderFact {
    let frame_index = current_provider_identity_frame(ctx)
    let file_key = ctx.struct_identity_file_key.unwrap_or("")
    let mut found: DelegateProviderFact? = none
    for fact in ctx.delegate_provider_unconsumed {
        if fact.file_key == file_key && fact.frame_index == frame_index &&
           fact.parent_decl_index == parent_decl_index &&
           fact.source_member_index == source_member_index {
            if found.is_some() {
                panic("impl provider ledger: duplicate delegate consume match")
            }
            found = some(fact)
        }
    }
    match found {
        some(fact) => fact,
        none => panic("impl provider ledger: missing delegate fact")
    }
}

pub fn commit_delegate_provider_fact(
    mut ctx: InferCtx, fact: DelegateProviderFact
) {
    let mut matches = 0
    let mut remaining: List<DelegateProviderFact> = []
    for existing in ctx.delegate_provider_unconsumed {
        if delegate_provider_fact_same(existing, fact) {
            matches = matches + 1
        } else {
            remaining.push(existing)
        }
    }
    if matches != 1 {
        panic("impl provider ledger: delegate commit mismatch")
    }
    ctx.delegate_provider_unconsumed = remaining
}

fn nominal_derived_provider_fact_same(
    left: NominalDerivedProviderPlanFact,
    right: NominalDerivedProviderPlanFact
) -> Bool {
    if left.file_key != right.file_key ||
       left.frame_index != right.frame_index ||
       left.decl_index != right.decl_index ||
       !impl_provider_ref_same(
            left.implicit_provider_ref, right.implicit_provider_ref) ||
       left.explicit_providers.len() != right.explicit_providers.len() {
        return false
    }
    for index in 0..left.explicit_providers.len() {
        match (left.explicit_providers.get(index),
               right.explicit_providers.get(index)) {
            (some(a), some(b)) => {
                if a.attr_index != b.attr_index ||
                   !impl_provider_ref_same(a.provider_ref, b.provider_ref) {
                    return false
                }
            },
            _ => return false
        }
    }
    true
}

pub fn peek_nominal_derived_provider_fact(
    ctx: InferCtx, decl_index: Int, attr_count: Int
) -> NominalDerivedProviderPlanFact {
    let frame_index = current_provider_identity_frame(ctx)
    let file_key = ctx.struct_identity_file_key.unwrap_or("")
    let mut found: NominalDerivedProviderPlanFact? = none
    for fact in ctx.nominal_derived_provider_unconsumed {
        if fact.file_key == file_key && fact.frame_index == frame_index &&
           fact.decl_index == decl_index {
            if found.is_some() {
                panic("impl provider ledger: duplicate nominal consume match")
            }
            found = some(fact)
        }
    }
    let fact = match found {
        some(value) => value,
        none => panic("impl provider ledger: missing nominal derive fact")
    }
    if fact.explicit_providers.len() != attr_count {
        panic("impl provider ledger: derive attribute count changed")
    }
    for index in 0..fact.explicit_providers.len() {
        match fact.explicit_providers.get(index) {
            some(explicit) => if explicit.attr_index != index {
                panic("impl provider ledger: derive attribute order changed")
            },
            none => panic("impl provider ledger: derive attribute fact missing")
        }
    }
    fact
}

pub fn commit_nominal_derived_provider_fact(
    mut ctx: InferCtx, fact: NominalDerivedProviderPlanFact
) {
    let mut matches = 0
    let mut remaining: List<NominalDerivedProviderPlanFact> = []
    for existing in ctx.nominal_derived_provider_unconsumed {
        if nominal_derived_provider_fact_same(existing, fact) {
            matches = matches + 1
        } else {
            remaining.push(existing)
        }
    }
    if matches != 1 {
        panic("impl provider ledger: nominal derive commit mismatch")
    }
    ctx.nominal_derived_provider_unconsumed = remaining
}

pub fn close_struct_identity_ledger(mut ctx: InferCtx) {
    if ctx.struct_identity_frame_stack.len() != 0 ||
       ctx.struct_identity_unconsumed.len() != 0 ||
       ctx.struct_identity_pending.len() != 0 ||
       ctx.trait_identity_unconsumed.len() != 0 ||
       ctx.source_impl_provider_unconsumed.len() != 0 ||
       ctx.delegate_provider_unconsumed.len() != 0 ||
       ctx.nominal_derived_provider_unconsumed.len() != 0 {
        panic("struct identity ledger: registration did not close")
    }
    ctx.struct_identity_file_key = none
    ctx.struct_identity_root_frame = none
    ctx.struct_identity_child_frames = map_new()
    ctx.struct_identity_frame_stack = []
    ctx.struct_identity_unconsumed = []
    ctx.struct_identity_pending = []
    ctx.trait_identity_unconsumed = []
    ctx.enum_identity_unconsumed = []
    ctx.effect_identity_unconsumed = []
    ctx.source_impl_provider_unconsumed = []
    ctx.delegate_provider_unconsumed = []
    ctx.nominal_derived_provider_unconsumed = []
}

fn bind_raw_extern_type_alias(mut ctx: InferCtx, alias_name: Str, abi_name: Str) -> Bool {
    match ctx.env.types.extern_structs.get(abi_name) {
        some(def) => {
            if def.is_extern {
                if alias_name != abi_name {
                    ctx.env.types.structs.insert(alias_name, def)
                }
                return true
            }
        },
        none => {}
    }
    false
}

fn bind_relative_import(
    mut ctx: InferCtx, local_name: Str, qualified_name: Str,
    published_identity: Str?
) -> Bool {
    // Snapshot before alias insertion: a real canonical struct with the same
    // leaf always wins over this file's raw ExternType ABI spelling.
    let exact_struct_found = ctx.env.types.structs.contains_key(qualified_name)
    // Both aliases consume the same immutable source key. The helper snapshots
    // value provenance before allocating either alias DefId.
    let mut found = bind_exact_import_alias(ctx, local_name, qualified_name, true)
    match published_identity {
        some(identity) => {
            if bind_exact_import_alias(ctx, identity, qualified_name, true) {
                found = true
            }
        },
        none => {}
    }

    // Extern types deliberately retain their raw ABI identity. Only an actual
    // declaration in this file may satisfy the relative module membership.
    let abi_name = import_identity_leaf(qualified_name)
    if !exact_struct_found && ctx.file_extern_types.contains(abi_name) {
        if bind_raw_extern_type_alias(ctx, local_name, abi_name) {
            found = true
        }
        match published_identity {
            some(identity) => {
                if bind_raw_extern_type_alias(ctx, identity, abi_name) {
                    found = true
                }
            },
            none => {}
        }
    }
    found
}

fn published_import_identity(ctx: InferCtx, is_pub: Bool, local_name: Str) -> Str? {
    if !is_pub || ctx.mod_path_stack.len() == 0 { return none }
    some("${ctx.mod_path_stack.join("::")}::${local_name}")
}

pub fn resolve_mod_uses(mut ctx: InferCtx, uses: List<UseDecl>, report_errors: Bool) {
    // Track which qualified source each imported local name came from, for ambiguity detection.
    let mut import_origins: Map<Str, Str> = map_new()

    for use_decl in uses {
        let segments = use_decl.path.segments
        if segments.len() == 0 { continue }
        let first = segments.get(0).unwrap_or("")
        if first != "self" && first != "super" { continue }

        let mut qualifier = first
        let mut name_start_idx = 1
        let mut i = 1
        while i < segments.len() {
            let seg = segments.get(i).unwrap_or("")
            if seg == "super" {
                qualifier = "${qualifier}::${seg}"
                name_start_idx = i + 1
            } else {
                break
            }
            i = i + 1
        }
        let remaining_end = match use_decl.imports {
            UseImport::NamedItems { names } => segments.len(),
            UseImport::Module => {
                if segments.len() > 0 { segments.len() - 1 } else { 0 }
            }
        }
        while i < remaining_end {
            let seg = segments.get(i).unwrap_or("")
            qualifier = "${qualifier}::${seg}"
            name_start_idx = i + 1
            i = i + 1
        }

        let resolved = resolve_relative_qualifier(qualifier, ctx.mod_path_stack)
        match resolved {
            none => {
                if report_errors {
                    let _ = type_error(ctx.sink, E0705,
                        "Cannot use '${qualifier}' — relative path exceeds module nesting depth",
                        use_decl.path.span,
                        DiagnosticContext::OtherContext { detail: some("relative path out of scope") })
                }
                continue
            },
            some(prefix) => {
                let canonical_prefix = canonical_relative_prefix(ctx, prefix)
                match use_decl.imports {
                    UseImport::NamedItems { names } => {
                        for item in names {
                            let local_name = match item.alias { some(a) => a, none => item.name }
                            let qualified_name = append_import_identity(canonical_prefix, item.name)
                            match import_origins.get(local_name) {
                                some(prev_qualified) => {
                                    if prev_qualified != qualified_name {
                                        let prev_display = nominal_display_name(prev_qualified)
                                        let qualified_display = nominal_display_name(qualified_name)
                                        if report_errors {
                                            let _ = type_error(ctx.sink, E0707,
                                                "Ambiguous name '${local_name}': imported from both '${prev_display}' and '${qualified_display}'. Use qualified name to disambiguate",
                                                item.span,
                                                DiagnosticContext::OtherContext { detail: some("ambiguous import") })
                                        }
                                        continue
                                    }
                                },
                                none => {}
                            }
                            let published_identity = published_import_identity(
                                ctx, use_decl.is_pub, local_name)
                            if bind_relative_import(
                                ctx, local_name, qualified_name,
                                published_identity
                            ) {
                                import_origins.insert(local_name, qualified_name)
                            } else {
                                let qualified_display = nominal_display_name(qualified_name)
                                if report_errors {
                                    let _ = type_error(ctx.sink, E0201,
                                        "Undefined import: ${qualified_display}",
                                        item.span,
                                        DiagnosticContext::UndefinedVariable { name: qualified_display, scope_locals: none })
                                }
                            }
                        }
                    },
                    UseImport::Module => {
                        if name_start_idx < segments.len() {
                            let name = segments.get(segments.len() - 1).unwrap_or("")
                            let local_name = match use_decl.alias { some(a) => a, none => name }
                            let qualified_name = append_import_identity(canonical_prefix, name)
                            match import_origins.get(local_name) {
                                some(prev_qualified) => {
                                    if prev_qualified != qualified_name {
                                        let prev_display = nominal_display_name(prev_qualified)
                                        let qualified_display = nominal_display_name(qualified_name)
                                        if report_errors {
                                            let _ = type_error(ctx.sink, E0707,
                                                "Ambiguous name '${local_name}': imported from both '${prev_display}' and '${qualified_display}'. Use qualified name to disambiguate",
                                                use_decl.path.span,
                                                DiagnosticContext::OtherContext { detail: some("ambiguous import") })
                                        }
                                        continue
                                    }
                                },
                                none => {}
                            }
                            let published_identity = published_import_identity(
                                ctx, use_decl.is_pub, local_name)
                            if bind_relative_import(
                                ctx, local_name, qualified_name,
                                published_identity
                            ) {
                                import_origins.insert(local_name, qualified_name)
                            } else {
                                let qualified_display = nominal_display_name(qualified_name)
                                if report_errors {
                                    let _ = type_error(ctx.sink, E0201,
                                        "Undefined import: ${qualified_display}",
                                        use_decl.path.span,
                                        DiagnosticContext::UndefinedVariable { name: qualified_display, scope_locals: none })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
