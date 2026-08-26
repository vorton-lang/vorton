use ast::{Span, Pattern, BinOp, UnaryOp, TypeParam}
use types::{Type, Effect, EffectRow, StructField, EnumVariant, RecordField,
    types_equal}
use ir_identity::{SymbolRef, NominalFieldRef, TraitMethodRef, ImplProviderRef,
    ImplOwnerRef, OriginRef,
    VariantRef, VariantFieldRef,
    HandledEffectRef,
    ImplMethodRef, IntrinsicRef, CalleeRef, SlotRef, PathRef, slot_ref_same,
    callee_ref_is_named, callee_ref_named_symbol,
    callee_ref_is_local, callee_ref_local_slot,
    slot_ref_is_source, slot_ref_source_def_id,
    slot_ref_source_domain_is_lexical,
    intrinsic_ref_same, impl_method_ref_same, trait_method_ref_same,
    intrinsic_ref_symbol, make_named_callee_ref,
    RegisteredNominalRef, RegisteredTraitRef, symbol_ref_same,
    nominal_field_ref_owner, nominal_field_ref_index, nominal_field_ref_same,
    nominal_field_ref_name, registered_nominal_ref_symbol,
    registered_nominal_ref_same,
    registered_nominal_ref_display_name,
    registered_trait_ref_symbol, registered_trait_ref_display_name,
    trait_method_ref_trait, trait_method_ref_source_member_index,
    trait_method_ref_callable_slot_index,
    trait_method_ref_name, trait_method_ref_member,
    impl_owner_ref_provider, impl_owner_ref_trait, impl_owner_ref_same,
    impl_method_ref_member, impl_method_ref_owner,
    variant_ref_owner, variant_ref_source_index, variant_ref_member,
    variant_field_ref_variant, variant_field_ref_index,
    variant_ref_same,
    handled_effect_ref_same, system_effect_ref_same,
    impl_provider_ref_same, impl_provider_ref_kind,
    impl_provider_kind_tag}
use ir_inventory::{ExecutableRef, EffectOperationRef, SystemHostCallableRef,
    BinderEntry, HandledEvidenceRef, HandledEvidenceCapture,
    CallableResourceContractFact,
    executable_ref_is_named, executable_ref_named_symbol,
    executable_ref_same,
    handled_evidence_requirement,
    handled_evidence_contract_owner, handled_evidence_ordinal,
    make_handled_evidence_capture,
    handled_evidence_capture_requirement,
    handled_evidence_capture_source, handled_evidence_capture_target,
    effect_operation_ref_effect,
    effect_operation_ref_source_index,
    system_host_callable_effect, system_host_callable_executable}

pub use hir_exact::{
    DictRef, MethodCallRef, make_intrinsic_method_call_ref, method_call_ref_intrinsic,
    make_concrete_method_call_ref, make_bound_method_call_ref, method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_is_bound, method_call_ref_impl, method_call_ref_bound, method_call_ref_bound_evidence,
    method_call_ref_signature, method_call_ref_receiver_mutable, method_call_ref_same, method_call_ref_named_symbol,
    method_call_ref_callee_identity, HPatternBinding, HProjectionRef, h_nominal_projection,
    h_variant_projection, h_structural_projection, h_tuple_projection, h_intrinsic_projection,
    h_projection_kind, h_projection_nominal, h_projection_variant, h_projection_structural,
    h_projection_structural_name, h_projection_tuple_index, h_projection_intrinsic, HExactCallPlan,
    make_h_exact_call_plan, h_exact_call_callee, h_exact_call_method,
    h_exact_call_evidence, h_exact_call_handled_evidence,
    remap_h_handled_evidence_ref, remap_h_handled_evidence_refs,
    remap_h_exact_call_handled_evidence,
    HOperatorPlan, h_operator_method, h_operator_tuple, h_operator_is_tuple,
    h_operator_method_ref, h_operator_elements, HConstructorPlan, make_h_executable_constructor_plan,
    make_h_tuple_constructor_plan, make_h_record_constructor_plan, h_constructor_kind, h_constructor_executable,
    h_constructor_fields, h_constructor_tuple_arity, HStringInterpPlan, make_h_string_interp_plan,
    h_string_interp_builder_binder, h_string_interp_builder, h_string_interp_append_literal, h_string_interp_append_value,
    h_string_interp_finish, h_string_interp_value_to_string,
    remap_h_string_interp_handled_evidence,
    HDictConstructPlan, make_h_dict_construct_plan,
    h_dict_construct_executable, h_dict_construct_trait, HDelegateMethodPlan, make_h_delegate_method_plan,
    h_delegate_method_required, h_delegate_method_generated, h_delegate_method_executable, h_delegate_method_origin,
    h_delegate_method_child_call, h_delegate_method_child_callee, h_delegate_method_binders, h_delegate_method_parameter_types,
    h_delegate_method_result_type, h_delegate_method_effects,
    h_delegate_method_evidence, h_delegate_method_handled_bindings,
    h_delegate_method_handled_uses, HDelegateAssocPlan,
    make_h_delegate_assoc_plan, h_delegate_assoc_member, h_delegate_assoc_type, HDelegateTypedPlan,
    make_h_delegate_typed_plan, h_delegate_contract,
    h_delegate_outer_owner, h_delegate_child_owner, h_delegate_child_provider,
    h_delegate_field_owner, h_delegate_field_provider, h_delegate_field_target, h_delegate_field,
    h_delegate_trait, h_delegate_source_member_index, h_delegate_methods, h_delegate_assoc_bindings,
    h_delegate_handled_evidence, h_delegate_dict_evidence, HPatternPlan, HPatternFieldPlan,
    HDefaultSpecializationPlan, make_h_default_specialization_plan,
    h_default_specialization_owner,
    h_default_specialization_generated_method,
    h_default_specialization_generated_executable,
    h_default_specialization_source_method,
    h_default_specialization_default_executable,
    h_default_specialization_parameter_types,
    h_default_specialization_parameter_mutabilities,
    h_default_specialization_binders,
    h_default_specialization_result_type,
    h_default_specialization_effects,
    h_default_specialization_forward_call,
    make_h_pattern_field_plan, h_pattern_field_projection, h_pattern_field_pattern, h_pattern_wildcard,
    h_pattern_binding, h_pattern_literal, h_pattern_tuple, h_pattern_struct,
    h_pattern_variant, h_pattern_or, h_pattern_kind, h_pattern_plan_binding,
    h_pattern_plan_children, h_pattern_plan_fields, h_pattern_plan_struct_owner, h_pattern_plan_variant,
    HForInPlan, make_h_for_in_plan, h_for_in_iter, h_for_in_has_next,
    h_for_in_next, h_for_in_iterator_binder, h_for_in_item_binder, h_for_in_binding_binder,
    h_for_in_destructure_binders, remap_h_for_in_handled_evidence,
    HFailOperationRef, h_fail_raise_ref, h_fail_operation_tag
}

pub use types::{BUILTIN_INT, BUILTIN_FLOAT, BUILTIN_STR, BUILTIN_BOOL,
    BUILTIN_RANGE, BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET,
    BUILTIN_OPTION, BUILTIN_CELL, BUILTIN_STRING_BUILDER}

pub use builtin_methods::{CELL_METHODS, STR_METHODS, INT_METHODS, FLOAT_METHODS,
    LIST_NON_HOF_METHODS, LIST_HOF_METHODS,
    MAP_NON_HOF_METHODS, MAP_HOF_METHODS,
    SET_NON_HOF_METHODS, SET_HOF_METHODS,
    OPTION_NON_HOF_METHODS, OPTION_HOF_METHODS,
    STRINGBUILDER_METHODS}

// Source and pattern/default binders use the checker's non-negative DefId
// allocator.  Later lowering passes use disjoint negative namespaces so a
// synthetic binding can never alias source HIR or another pass's binding.
pub const SYNTHETIC_DICT_DEF_ID_BASE: Int = 0 - 3000000000
pub const SYNTHETIC_ANF_DEF_ID_BASE: Int = 0 - 4000000000
pub const SYNTHETIC_RC_DEF_ID_BASE: Int = 0 - 5000000000
pub const SYNTHETIC_DEF_ID_NAMESPACE_SIZE: Int = 1000000000

pub fn synthetic_def_id(base: Int, ordinal: Int) -> Int {
    if ordinal <= 0 || ordinal >= SYNTHETIC_DEF_ID_NAMESPACE_SIZE {
        panic("unreachable: synthetic DefId namespace exhausted")
    }
    base - ordinal
}

pub fn is_synthetic_dict_def_id(def_id: Int) -> Bool {
    def_id < SYNTHETIC_DICT_DEF_ID_BASE &&
        def_id > SYNTHETIC_DICT_DEF_ID_BASE -
            SYNTHETIC_DEF_ID_NAMESPACE_SIZE
}

// Callable values installed directly by builtins.ring rather than parsed from
// a Decl. Checker provenance and both native backends must consume this one
// list so a newly added checker-only callable cannot drift across phases.
// File-module declaration identity. `$` is not legal in a Ring identifier,
// while resolver module prefixes use `$` between path segments.  Therefore
// `$$_` is an unambiguous boundary between a module path and its declaration;
// inline-module components remain after the declaration as `::child`.
//
// This string is an internal identity, never a user-facing display name.
pub fn module_item_identity(module_prefix: Str, decl_name: Str) -> Str {
    "${module_prefix}$$_${decl_name}"
}

pub fn is_module_item_identity(name: Str) -> Bool {
    name.index_of("$$_").is_some()
}

// One user-declared impl block, described by the identity the checker's
// registration pass resolved while the module's namespace frames were still
// live. Export extraction runs after the frame journal has been rolled back,
// so it must consume these persisted facts instead of re-resolving the impl
// target spelling against a dead environment (checker/exports shared
// contract; see check_impl_decl and extract_exports).
pub struct ModuleImplFact {
    // Canonical nominal identity chosen by resolve_nominal_identity during
    // checking: a declaration identity for user types, the bare builtin
    // spelling (e.g. "Str") for builtin impls.
    pub target: Str,
    pub provider_ref: ImplProviderRef,
    pub trait_ref: SymbolRef?,
    pub owner_ref: ImplOwnerRef,
    // fn-method names in declaration order (delegates excluded upstream by
    // HIR construction only when they do not lower to HDecl::Fn).
    pub method_names: List<Str>,
    // Existing HDecl::Fn visibility projected only for inherent impls. Trait
    // impl surface is governed by target+trait visibility, never a member bit.
    pub public_inherent_method_names: List<Str>,
    // True for impls declared at file level (frame zero); inline-mod impls
    // keep the public-frame gate applied during collection.
    pub is_top_level: Bool
}

// Foreign declarations have two independent identities: `HDecl::ExternFn.name`
// is the exact Ring declaration identity used by lookup/provenance, while the
// ABI symbol remains the final source leaf. Keeping this split explicit stops
// equal extern leaves in different modules from contaminating backend lookup.
pub fn extern_abi_leaf(identity: Str) -> Str {
    let inline_parts = identity.split("::")
    let inline_leaf = inline_parts.get(inline_parts.len() - 1).unwrap_or(identity)
    let file_parts = inline_leaf.split("$$_")
    file_parts.get(file_parts.len() - 1).unwrap_or(inline_leaf)
}

// Compiler-synthesised definitions live below an unspellable module prefix.
// Resolver path segments come only from a filesystem basename after `/` and
// `\` have been split away, or from a legal use/inline-module identifier.
// Therefore no segment can contain `/`; module_prefix joins segments only with
// `$`, so no source declaration identity can begin with this sentinel.
fn compiler_intrinsic_identity(namespace: Str, source_name: Str) -> Str {
    module_item_identity("/$compiler_intrinsic$${namespace}", source_name)
}

// Synthetic Map indexing must bypass every user-spellable binding while the
// raw helper remains available as an ordinary prelude API.  Checker and infer
// share both spellings here so neither phase can drift from the other.
pub fn map_index_helper_source_name() -> Str {
    "map_get_panic"
}

pub fn map_index_helper_identity() -> Str {
    compiler_intrinsic_identity("prelude$map", map_index_helper_source_name())
}

// The raw slot bridge spellings remain callable prelude APIs, so their
// ownership contracts must not attach to those user-spellable names.  The
// checker records these unspellable identities on the exact prelude DefIds;
// RC and both native backends consume only the identities below.
pub fn slot_read_source_name() -> Str {
    "ring_slot_read"
}

pub fn slot_take_source_name() -> Str {
    "ring_slot_take"
}

pub fn slot_write_source_name() -> Str {
    "ring_slot_write"
}

pub fn slot_drop_source_name() -> Str { "ring_slot_drop" }
pub fn list_sort_bridge_source_name() -> Str { "ring_list_sort_bridge" }

fn slot_bridge_identity(role: Str) -> Str {
    compiler_intrinsic_identity("prelude$slot", role)
}

pub fn slot_read_identity() -> Str {
    slot_bridge_identity("read")
}

pub fn slot_take_identity() -> Str {
    slot_bridge_identity("take")
}

pub fn slot_write_identity() -> Str {
    slot_bridge_identity("write")
}

pub fn slot_drop_identity() -> Str {
    slot_bridge_identity("drop")
}

pub fn list_sort_bridge_identity() -> Str {
    compiler_intrinsic_identity("prelude$list", "sort")
}

// Every parsed top-level prelude extern receives an unspellable semantic
// identity. This keeps its declaration distinct from a user fn/const with the
// same leaf in every project module; `HDecl::ExternFn.abi_name` remains raw.
// Slot bridges retain their specific identities because RC consumes those
// exact ownership contracts.
pub fn prelude_extern_identity(source_name: Str) -> Str {
    if source_name == slot_read_source_name() { return slot_read_identity() }
    if source_name == slot_take_source_name() { return slot_take_identity() }
    if source_name == slot_write_source_name() { return slot_write_identity() }
    if source_name == slot_drop_source_name() { return slot_drop_identity() }
    if source_name == list_sort_bridge_source_name() {
        return list_sort_bridge_identity()
    }
    compiler_intrinsic_identity("prelude$extern", source_name)
}

// Convert only a proven prelude slot identity back to its C ABI symbol.
// Ordinary Ring bindings with the same source spelling intentionally miss.
pub fn slot_bridge_runtime_name(identity: Str) -> Str? {
    if identity == slot_read_identity() { return some(slot_read_source_name()) }
    if identity == slot_take_identity() { return some(slot_take_source_name()) }
    if identity == slot_write_identity() { return some(slot_write_source_name()) }
    none
}

pub struct HParam {
    pub name: Str,
    pub ty: Type,
    pub def_id: Int?,
    pub is_mutable: Bool
}

// B-104 D4: a module-level static dict singleton definition (HProgram.static_dicts).
//   inner == []  — a PLAIN static dict (impl dict or builtin primitive dict).
//                  Its definition already exists (ring_dict_init_* / runtime
//                  builtin synthesis); the entry records the module's
//                  static-dict footprint and codegen memoises the named
//                  singleton on first use.
//                  trait_name may be "" (not recoverable from the name alone —
//                  backends do not need it for plain dicts).
//   inner != [] — a fully-static WRAPPED INSTANCE: base_dict's trait methods
//                  partially applied with the inner singletons.  Codegen emits
//                  ONE module-level definition (lazy memoised getter) and use
//                  sites borrow it via DictRef::Static.
pub struct HDictDef {
    pub name: Str,
    pub base_dict: Str,
    pub trait_name: Str,
    pub inner: List<Str>
}

// Naming convention for a fully-static wrapped dict instance (cross-stage
// contract: dict_lower mints it, codegen defines/references it).  `$` is
// legal in LLVM symbols (and JS identifiers in dist/), and cannot appear in user type
// names, so the encoding is collision-free and deterministic.
pub fn dict_instance_name(base_dict: Str, inner: List<Str>) -> Str {
    if inner.len() == 0 {
        base_dict
    } else {
        "${base_dict}$${inner.join("$")}"
    }
}

pub enum TraitDispatch {
    Builtin,
    Direct { dict: Str, extra_dicts: List<DictRef> },
    Dict { param: Str },
    // Tuple equality is structural, but every element still follows the
    // ordinary Eq resolver (builtin, direct impl, or an in-scope dictionary).
    // Keeping that resolved evidence in HIR makes both backends consumers of
    // one authoritative plan instead of re-deriving trait rules in codegen.
    Tuple { element_types: List<Type>, elements: List<TraitDispatch> }
}

pub struct HStructFieldInit {
    pub name: Str,
    pub field_ref: VariantFieldRef,
    pub value: HExpr
}

pub struct HNominalStructFieldInit {
    pub name: Str,
    pub field_ref: NominalFieldRef,
    pub field_index: Int,
    pub value: HExpr
}

pub enum HFieldAccessKind {
    NominalField { owner_ref: RegisteredNominalRef,
                   field_ref: NominalFieldRef, field_index: Int },
    RecordField,
    TupleField,
    Method,
    ErrorRecovery
}

pub struct HMatchArm {
    pub pattern: Pattern,
    pub pattern_plan: HPatternPlan?,
    pub bindings: List<HPatternBinding>,
    pub guard: HExpr?,
    pub body: HExpr,
    pub span: Span
}

pub struct HEffectHandler {
    pub effect_name: Str,
    pub handled_ref: HandledEffectRef?,
    pub operation_ref: EffectOperationRef?,
    pub fail_ref: HFailOperationRef?,
    pub executable_ref: ExecutableRef,
    pub captures: List<HLambdaCapture>,
    pub handled_evidence_bindings: List<HandledEvidenceRef>,
    pub evidence_captures: List<HandledEvidenceCapture>,
    pub op_name: Str,
    pub params: List<HParam>,
    pub resume_binding: HPatternBinding?,
    pub body: HExpr
}

pub enum HStringInterpPart {
    Literal(Str),
    Expression(HExpr)
}

pub struct HLambdaCapture {
    pub source: SlotRef,
    pub target: SlotRef,
    pub value: HExpr?,
    pub resource_site: HResourceSite?
}

// Lossless bridge identity for one frozen Flow semantic step. HIR cannot
// import FlowIR because FlowIR consumes DictRef, so the bridge copies the
// exact executable and ordinals into this closed representation.
pub struct HResourceSite {
    owner: ExecutableRef,
    block_ordinal: Int,
    instruction_ordinal: Int?
}

pub fn make_h_instruction_resource_site(
    owner: ExecutableRef, block_ordinal: Int, instruction_ordinal: Int
) -> HResourceSite {
    if block_ordinal < 0 || instruction_ordinal < 0 {
        panic("HIR resource site: negative instruction ordinal")
    }
    HResourceSite { owner: owner, block_ordinal: block_ordinal,
        instruction_ordinal: some(instruction_ordinal) }
}

pub fn make_h_terminator_resource_site(
    owner: ExecutableRef, block_ordinal: Int
) -> HResourceSite {
    if block_ordinal < 0 {
        panic("HIR resource site: negative terminator ordinal")
    }
    HResourceSite { owner: owner, block_ordinal: block_ordinal,
        instruction_ordinal: none }
}

pub fn h_resource_site_owner(value: HResourceSite) -> ExecutableRef {
    value.owner
}
pub fn h_resource_site_block_ordinal(value: HResourceSite) -> Int {
    value.block_ordinal
}
pub fn h_resource_site_instruction_ordinal(value: HResourceSite) -> Int? {
    value.instruction_ordinal
}
pub fn h_resource_site_same(
    left: HResourceSite, right: HResourceSite
) -> Bool {
    executable_ref_same(left.owner, right.owner) &&
        left.block_ordinal == right.block_ordinal &&
        left.instruction_ordinal == right.instruction_ordinal
}

const H_RESOURCE_TAKE: Int = 0
const H_RESOURCE_DROP: Int = 1
const H_RESOURCE_CLEANUP: Int = 2
const H_RESOURCE_SCOPE_END: Int = 3
const H_RESOURCE_DROP_PROJECTED_OLD: Int = 4

pub struct HResourceReason { tag: Int }
fn h_resource_reason_from_tag(tag: Int) -> HResourceReason {
    if tag < H_RESOURCE_TAKE || tag > H_RESOURCE_DROP_PROJECTED_OLD {
        panic("HIR resource reason: invalid tag")
    }
    HResourceReason { tag: tag }
}
pub fn h_resource_reason_take() -> HResourceReason {
    h_resource_reason_from_tag(H_RESOURCE_TAKE)
}
pub fn h_resource_reason_drop() -> HResourceReason {
    h_resource_reason_from_tag(H_RESOURCE_DROP)
}
pub fn h_resource_reason_cleanup() -> HResourceReason {
    h_resource_reason_from_tag(H_RESOURCE_CLEANUP)
}
pub fn h_resource_reason_scope_end() -> HResourceReason {
    h_resource_reason_from_tag(H_RESOURCE_SCOPE_END)
}
pub fn h_resource_reason_drop_projected_old() -> HResourceReason {
    h_resource_reason_from_tag(H_RESOURCE_DROP_PROJECTED_OLD)
}
pub fn h_resource_reason_tag(value: HResourceReason) -> Int {
    h_resource_reason_from_tag(value.tag).tag
}

// Exact checker provenance for value bindings whose source-level type alone
// cannot determine how an identifier must be evaluated. LocalBorrow is the
// fail-closed default when a DefId has no explicit registration provenance.
pub enum ValueBindingKind {
    DirectCallable,
    // Extern/builtin direct ABI accepts no Ring trait-dictionary parameters,
    // even when its type scheme carries bounds for static checking.
    ExternCallable,
    ConstGetter,
    LocalBorrow
}

pub enum HExpr {
    IntLit { value: Int, ty: Type, effects: EffectRow, span: Span },
    FloatLit { value: Float, ty: Type, effects: EffectRow, span: Span },
    StrLit { value: Str, ty: Type, effects: EffectRow, span: Span },
    BoolLit { value: Bool, ty: Type, effects: EffectRow, span: Span },
    Ident { name: Str, resolved_name: Str?, def_id: Int?,
            source_slot: SlotRef?, callee_identity: CalleeRef?,
            dict_closure_dicts: List<DictRef>?, ty: Type,
            effects: EffectRow, span: Span },
    BinOp { op: BinOp, left: HExpr, right: HExpr,
            eq_dispatch: TraitDispatch?, ord_dispatch: TraitDispatch?,
            eq_plan: HOperatorPlan?, ord_plan: HOperatorPlan?,
            ty: Type, effects: EffectRow, span: Span },
    UnaryOp { op: UnaryOp, operand: HExpr, ty: Type, effects: EffectRow, span: Span },
    Call { callee: HExpr, args: List<HExpr>, type_args: List<Type>, resolved_dicts: List<DictRef>, handled_evidence: List<HandledEvidenceRef>, callee_ref: CalleeRef?, method_ref: MethodCallRef?, system_host: SystemHostCallableRef?, ty: Type, effects: EffectRow, span: Span },
    FieldAccess { receiver: HExpr, field: Str,
                  access_kind: HFieldAccessKind,
                  projection: HProjectionRef?, ty: Type,
                  effects: EffectRow, span: Span },
    StructLit { name: Str, owner_ref: RegisteredNominalRef,
                type_args: List<Type>, fields: List<HNominalStructFieldInit>,
                spread: HExpr?, constructor: HConstructorPlan?,
                ty: Type, effects: EffectRow, span: Span },
    NamedVariantConstruct { enum_name: Str, variant_name: Str,
                            variant_ref: VariantRef,
                            fields: List<HStructFieldInit>, spread: HExpr?,
                            constructor: HConstructorPlan?, ty: Type,
                            effects: EffectRow, span: Span },
    MatchExpr { scrutinee: HExpr, arms: List<HMatchArm>, ty: Type, effects: EffectRow, span: Span },
    Block { stmts: List<HStmt>, tail: HExpr?, ty: Type, effects: EffectRow, span: Span },
    IfExpr { condition: HExpr, then_branch: HExpr, else_branch: HExpr?, ty: Type, effects: EffectRow, span: Span },
    StringInterp { parts: List<HStringInterpPart>, plan: HStringInterpPlan?,
                   ty: Type, effects: EffectRow, span: Span },
    TryCatch { body: HExpr, arms: List<HMatchArm>, ty: Type, effects: EffectRow, span: Span },
    HandleExpr { body: HExpr, handlers: List<HEffectHandler>, installed_evidence: List<HandledEvidenceRef>, ty: Type, effects: EffectRow, span: Span },
    Lambda { executable_ref: ExecutableRef, params: List<HParam>,
             captures: List<HLambdaCapture>,
             handled_evidence_bindings: List<HandledEvidenceRef>,
             evidence_captures: List<HandledEvidenceCapture>, return_type: Type,
             body: HExpr, ty: Type, effects: EffectRow, span: Span },
    EffectOp { effect_name: Str, op_name: Str,
               operation_ref: EffectOperationRef?,
               fail_ref: HFailOperationRef?,
               handled_evidence: List<HandledEvidenceRef>, args: List<HExpr>,
               ty: Type, effects: EffectRow, span: Span },
    RangeExpr { start: HExpr, end: HExpr, inclusive: Bool,
                constructor: HConstructorPlan?, ty: Type,
                effects: EffectRow, span: Span },
    ListLit { elements: List<HExpr>, constructor: HConstructorPlan?,
              ty: Type, effects: EffectRow, span: Span },
    TupleLit { elements: List<HExpr>, constructor: HConstructorPlan?,
               ty: Type, effects: EffectRow, span: Span },
    IndexExpr { receiver: HExpr, index: HExpr,
                call_plan: HExactCallPlan?, projection: HProjectionRef?,
                ty: Type, effects: EffectRow, span: Span },
    // B-104 D4 (#151): LOCAL construction of a DYNAMIC wrapped dict (at least
    // one inner is a dict param / dict local — unknowable at module scope).
    // Synthesised by dict_lower as the init of a `let __ring_dictlocal_N = …`
    // immediately above the consuming call; the binding is FRESH-OWNED and is
    // reclaimed by the ordinary Perceus scope-end drop (D1/D2 coverage).
    // `inner` entries are Simple (param/local borrow) or Static (singleton
    // borrow) — never Wrapped (dict_lower flattens nested dynamics into their
    // own locals first).  ty is TupleType{[]} (a dict IS a tuple of method
    // closures); effects are pure.
    DictConstruct { base_dict: Str, plan: HDictConstructPlan?,
                    inner: List<DictRef>, ty: Type,
                    effects: EffectRow, span: Span },
    // B-098: value-level clone inserted by the Perceus L1 borrow-inference pass
    // (clone-all-escape).  Wraps an escaping value that
    // already has an independent owner (Ident binding / FieldAccess / IndexExpr /
    // container read result) so the escape gets its own owned reference rather
    // than aliasing the still-live source.  codegen lowers `Clone{inner}` to
    // eval inner -> ring_dup(result) -> result (ty/effects/span taken from inner).
    Clone { inner: HExpr, ty: Type, effects: EffectRow, span: Span },
    Take { source: HExpr, source_slot: SlotRef, saved_slot: SlotRef?,
           site: HResourceSite, ty: Type, effects: EffectRow, span: Span },
    ReturnExpr { value: HExpr?, ty: Type, effects: EffectRow, span: Span },
    UnsafeBlock { body: HExpr, ty: Type, effects: EffectRow, span: Span }
}

pub struct HForInDestructure {
    pub name: Str,
    pub def_id: Int?,
    pub slot: SlotRef?,
    pub projection: HProjectionRef?
}

pub struct HLetDestructureBinding {
    pub name: Str,
    pub def_id: Int?,
    pub slot: SlotRef?,
    pub projection: HProjectionRef?,
    pub ty: Type
}

pub enum HStmt {
    Let { name: Str, name_span: Span, def_id: Int?, ty: Type, init: HExpr, span: Span },
    Var { name: Str, name_span: Span, def_id: Int?, ty: Type, init: HExpr, span: Span },
    Assign { target: HExpr, value: HExpr, span: Span },
    ExprStmt { expr: HExpr, span: Span },
    Return { value: HExpr?, span: Span },
    While { condition: HExpr, body: HExpr, span: Span },
    ForIn { binding: Str, binding_span: Span, def_id: Int?,
            destructure: List<HForInDestructure>?, plan: HForInPlan?,
            iterable: HExpr, body: HExpr, iterable_type_name: Str?,
            iter_type_name: Str?, span: Span },
    Break { span: Span },
    Continue { span: Span },
    LetDestructure { pattern: Pattern, pattern_plan: HPatternPlan?,
                     bindings: List<HLetDestructureBinding>,
                     init: HExpr, span: Span },
    IfLet { pattern: Pattern, pattern_plan: HPatternPlan?,
            bindings: List<HPatternBinding>, expr: HExpr,
            then_block: HExpr, else_block: HExpr?, span: Span },

    // Perceus RC: explicit reference counting op inserted by the RC pass.
    Drop { name: Str, def_id: Int, slot: SlotRef,
           place_target: HExpr?, site: HResourceSite,
           reason: HResourceReason, ty: Type, span: Span }
}

pub struct HStructField {
    pub name: Str,
    pub ty: Type,
    pub is_pub: Bool,
    pub field_ref: NominalFieldRef,
    pub field_index: Int,
    pub span: Span
}

pub struct HEnumVariant {
    pub name: Str,
    pub variant_ref: VariantRef,
    pub fields: List<Type>,
    pub field_refs: List<VariantFieldRef>,
    pub field_names: List<Str>?
}

pub struct HEffectOp {
    pub name: Str,
    pub operation_ref: EffectOperationRef?,
    pub params: List<HParam>,
    pub return_type: Type
}

pub struct HTraitMethod {
    pub name: Str,
    pub method_ref: TraitMethodRef,
    pub params: List<HParam>,
    pub return_type: Type,
    pub effects: EffectRow,
    pub has_default: Bool,
    pub executable_ref: ExecutableRef,
    pub handled_evidence_bindings: List<HandledEvidenceRef>,
    pub body: HExpr?
}

pub struct TraitBound {
    pub type_param: Str,
    pub type_var_id: Int,
    pub trait_name: Str,
    pub trait_ref: SymbolRef,
    pub dict_ordinal: Int
}

pub struct HAssocType {
    pub name: Str,
    pub member_ref: SymbolRef,
    pub bounds: List<Str>,
    pub concrete: Type?
}

pub struct HTypeParam {
    pub source: TypeParam,
    pub type_var_id: Int,
    pub bound_refs: List<SymbolRef>
}

pub fn h_type_param_source(value: HTypeParam) -> TypeParam { value.source }
pub fn h_type_param_name(value: HTypeParam) -> Str { value.source.name }
pub fn h_type_param_sources(values: List<HTypeParam>) -> List<TypeParam> {
    values.map(fn(value) { value.source })
}

pub enum HDecl {
    Fn { name: Str, def_id: Int?, executable_ref: ExecutableRef,
         impl_method_ref: ImplMethodRef?, type_params: List<HTypeParam>,
         params: List<HParam>, return_type: Type, effects: EffectRow,
         handled_evidence_bindings: List<HandledEvidenceRef>,
         body: HExpr, is_pub: Bool, trait_bounds: List<TraitBound>, span: Span },
    Struct { name: Str, owner_ref: RegisteredNominalRef, type_params: List<HTypeParam>, fields: List<HStructField>, is_pub: Bool, span: Span },
    Enum { name: Str, owner_ref: RegisteredNominalRef, type_params: List<HTypeParam>, variants: List<HEnumVariant>, is_pub: Bool, span: Span },
    Impl { target_type: Str, target_ty: Type, owner_ref: ImplOwnerRef,
           provider_ref: ImplProviderRef, trait_ref: SymbolRef?,
           delegate_plan: HDelegateTypedPlan?,
           default_specializations: List<HDefaultSpecializationPlan>,
           type_params: List<HTypeParam>, trait_name: Str?,
           methods: List<HDecl>, assoc_types: List<HAssocType>, span: Span },
    Effect { name: Str, owner_ref: SymbolRef?, handled_ref: HandledEffectRef?, type_params: List<HTypeParam>, ops: List<HEffectOp>, is_pub: Bool, span: Span },
    Test { description: Str, executable_ref: ExecutableRef,
           handled_evidence_bindings: List<HandledEvidenceRef>,
           body: HExpr, span: Span },
    Trait { name: Str, owner_ref: RegisteredTraitRef, type_params: List<HTypeParam>, methods: List<HTraitMethod>, supertraits: List<Str>, assoc_types: List<HAssocType>, is_pub: Bool, span: Span },
    ExternFn { name: Str, abi_name: Str, def_id: Int?,
               executable_ref: ExecutableRef, type_params: List<HTypeParam>,
               params: List<HParam>, return_type: Type, effects: EffectRow,
               resource_contract: CallableResourceContractFact,
               handled_evidence_bindings: List<HandledEvidenceRef>,
               trait_bounds: List<TraitBound>,
               is_pub: Bool, span: Span },
    ExternType { name: Str, type_params: List<HTypeParam>, is_pub: Bool, span: Span },
    TypeAlias { name: Str, ty: Type, is_pub: Bool, span: Span },
    Const { name: Str, def_id: Int?, executable_ref: ExecutableRef,
            handled_evidence_bindings: List<HandledEvidenceRef>,
            ty: Type, init: HExpr, is_pub: Bool, span: Span },
    ModBlock { name: Str, decls: List<HDecl>, is_pub: Bool, span: Span }
}

pub enum FieldAction {
    // Eq/Clone/Ord/Debug may use primitive identity actions.  Hash derivation
    // intentionally uses Call/Tuple only so every leaf is backed by Hash
    // evidence and no backend can fall back to an address-derived value.
    Identity,
    FloatIdentity,
    BoolIdentity,
    // Base and trailing type-param evidence both retain explicit provenance.
    // A bound base is Simple; a module singleton base is Static.  Wrapped
    // bases normalize to Static(base) plus their tagged inner refs.
    Call { method_ref: MethodCallRef, base_dict: DictRef,
           extra_dicts: List<DictRef> },
    Tuple { element_types: List<Type>,
            element_projections: List<HProjectionRef>,
            element_actions: List<FieldAction> },
    FnLiteral
}

pub enum DerivedFieldRef {
    NominalDerivedField(NominalFieldRef),
    VariantDerivedField(VariantFieldRef)
}

pub struct DerivedField {
    pub name: Str,
    pub positional_index: Int?,
    pub field_ref: DerivedFieldRef,
    pub ty: Type,
    pub action: FieldAction,
    // Ord comparison results are semantic generated lets: the same exact
    // value feeds both the zero test and early return, so Core must never
    // duplicate the method call while lowering structured control.
    pub ord_result_binder: BinderEntry?
}

pub struct DerivedVariant {
    pub name: Str,
    pub variant_ref: VariantRef,
    // Stable declaration-order discriminator mixed into derived Hash before
    // payload fields.  This is a front-end contract, not a backend type/name
    // hash or allocation-dependent value.
    pub discriminator: Int,
    pub fields: List<DerivedField>,
    pub has_named_fields: Bool
}

pub enum DerivedTextPiece {
    DerivedLiteralText(Str),
    DerivedFieldText(DerivedFieldRef),
    // A payload field whose Debug/Json representation is a fixed literal
    // still carries its exact identity so enum pattern coverage remains total.
    DerivedFieldLiteralText { field: DerivedFieldRef, value: Str }
}

pub struct DerivedTextSequence {
    pub pieces: List<DerivedTextPiece>
}

pub struct DerivedTextVariant {
    pub variant_ref: VariantRef,
    pub sequence: DerivedTextSequence
}

pub struct DerivedTextPlan {
    pub builder_binder: BinderEntry,
    pub builder: HExactCallPlan,
    pub builder_signature: Type,
    pub append: HExactCallPlan,
    pub finish: HExactCallPlan,
    pub struct_sequence: DerivedTextSequence?,
    pub variants: List<DerivedTextVariant>?
}

pub enum TypeKind { StructKind, EnumKind }

// Shared initial state for C/LLVM structural Hash emission.  Kept within the
// signed 63-bit Ring Int range so boxing/unboxing is identical in both
// backends.
pub const DERIVED_HASH_SEED: Int = 1469598103934665603

pub enum DerivedSemanticKind {
    DerivedEqPrimary,
    DerivedEqNe,
    DerivedHash,
    DerivedClone,
    DerivedOrd,
    DerivedDebug,
    DerivedJson
}

pub fn derived_semantic_kind_tag(value: DerivedSemanticKind) -> Int {
    match value {
        DerivedSemanticKind::DerivedEqPrimary => 0,
        DerivedSemanticKind::DerivedEqNe => 1,
        DerivedSemanticKind::DerivedHash => 2,
        DerivedSemanticKind::DerivedClone => 3,
        DerivedSemanticKind::DerivedOrd => 4,
        DerivedSemanticKind::DerivedDebug => 5,
        DerivedSemanticKind::DerivedJson => 6
    }
}

pub struct DerivedMethod {
    pub semantic_kind: DerivedSemanticKind,
    pub method_ref: ImplMethodRef,
    pub executable_ref: ExecutableRef,
    pub signature: Type,
    pub binders: List<BinderEntry>,
    pub handled_evidence_bindings: List<HandledEvidenceRef>
}

pub struct DerivedDirectCall {
    pub plan: HExactCallPlan,
    pub signature: Type
}

pub struct DerivedImpl {
    pub semantic_kind: DerivedSemanticKind,
    pub owner_ref: ImplOwnerRef,
    pub provider_ref: ImplProviderRef,
    pub trait_ref: SymbolRef,
    pub target_owner: RegisteredNominalRef,
    pub target_type: Type,
    pub methods: List<DerivedMethod>,
    pub hash_mix: DerivedDirectCall?,
    pub text_plan: DerivedTextPlan?,
    pub type_name: Str,
    pub trait_name: Str,
    pub type_params: List<HTypeParam>,
    pub bounds: List<TraitBound>,
    pub type_kind: TypeKind,
    pub struct_fields: List<DerivedField>?,
    pub enum_variants: List<DerivedVariant>?
}

pub struct HProgram {
    pub decls: List<HDecl>,
    pub derived_impls: List<DerivedImpl>,
    pub boxed_vars: Set<Int>,
    // B-104 D4: the module's static dict singleton set (see HDictDef), collected
    // by dict_lower (checker pipeline) in registration order (inners before the
    // wrapped instances that reference them).
    pub static_dicts: List<HDictDef>,
    // B-144: global set of extern type names, collected at checker phase across
    // all modules.  perceus / codegen_c / verify_rc read this instead of
    // re-collecting per-module (which misses use-imported extern types).
    pub extern_type_names: Set<Str>,
    // B-002p1: types with user `impl Drop` — perceus skips dup (move semantics),
    // codegen calls user drop body in ring_drop_T, move checker prevents UAM.
    pub drop_types: Set<Str>
}

fn remap_h_evidence_capture(
    value: HandledEvidenceCapture, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> HandledEvidenceCapture {
    make_handled_evidence_capture(
        handled_evidence_capture_requirement(value),
        remap_h_handled_evidence_ref(
            handled_evidence_capture_source(value), sources, targets),
        remap_h_handled_evidence_ref(
            handled_evidence_capture_target(value), sources, targets))
}

fn remap_h_evidence_captures(
    values: List<HandledEvidenceCapture>, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> List<HandledEvidenceCapture> {
    let mut result: List<HandledEvidenceCapture> = []
    for value in values {
        result.push(remap_h_evidence_capture(value, sources, targets))
    }
    result
}

fn remap_h_lambda_captures(
    values: List<HLambdaCapture>, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> List<HLambdaCapture> {
    let mut result: List<HLambdaCapture> = []
    for value in values {
        result.push(HLambdaCapture {
            source: value.source, target: value.target,
            value: value.value.map(fn(expr) {
                remap_hir_handled_evidence(expr, sources, targets)
            }),
            resource_site: value.resource_site
        })
    }
    result
}

fn remap_h_match_arms(
    values: List<HMatchArm>, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> List<HMatchArm> {
    let mut result: List<HMatchArm> = []
    for value in values {
        result.push(HMatchArm {
            pattern: value.pattern, pattern_plan: value.pattern_plan,
            bindings: value.bindings,
            guard: value.guard.map(fn(expr) {
                remap_hir_handled_evidence(expr, sources, targets)
            }),
            body: remap_hir_handled_evidence(
                value.body, sources, targets),
            span: value.span
        })
    }
    result
}

fn remap_h_stmt_handled_evidence(
    value: HStmt, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> HStmt {
    match value {
        HStmt::Let { name, name_span, def_id, ty, init, span } => HStmt::Let {
            name: name, name_span: name_span, def_id: def_id, ty: ty,
            init: remap_hir_handled_evidence(init, sources, targets),
            span: span
        },
        HStmt::Var { name, name_span, def_id, ty, init, span } => HStmt::Var {
            name: name, name_span: name_span, def_id: def_id, ty: ty,
            init: remap_hir_handled_evidence(init, sources, targets),
            span: span
        },
        HStmt::Assign { target, value, span } => HStmt::Assign {
            target: remap_hir_handled_evidence(target, sources, targets),
            value: remap_hir_handled_evidence(value, sources, targets),
            span: span
        },
        HStmt::ExprStmt { expr, span } => HStmt::ExprStmt {
            expr: remap_hir_handled_evidence(expr, sources, targets),
            span: span
        },
        HStmt::Return { value, span } => HStmt::Return {
            value: value.map(fn(expr) {
                remap_hir_handled_evidence(expr, sources, targets)
            }), span: span
        },
        HStmt::While { condition, body, span } => HStmt::While {
            condition: remap_hir_handled_evidence(
                condition, sources, targets),
            body: remap_hir_handled_evidence(body, sources, targets),
            span: span
        },
        HStmt::ForIn {
            binding, binding_span, def_id, destructure, plan,
            iterable, body, iterable_type_name, iter_type_name, span
        } => HStmt::ForIn {
            binding: binding, binding_span: binding_span, def_id: def_id,
            destructure: destructure,
            plan: plan.map(fn(value) {
                remap_h_for_in_handled_evidence(value, sources, targets)
            }),
            iterable: remap_hir_handled_evidence(
                iterable, sources, targets),
            body: remap_hir_handled_evidence(body, sources, targets),
            iterable_type_name: iterable_type_name,
            iter_type_name: iter_type_name, span: span
        },
        HStmt::Break { span } => HStmt::Break { span: span },
        HStmt::Continue { span } => HStmt::Continue { span: span },
        HStmt::LetDestructure {
            pattern, pattern_plan, bindings, init, span
        } => HStmt::LetDestructure {
            pattern: pattern, pattern_plan: pattern_plan, bindings: bindings,
            init: remap_hir_handled_evidence(init, sources, targets),
            span: span
        },
        HStmt::IfLet {
            pattern, pattern_plan, bindings, expr,
            then_block, else_block, span
        } => HStmt::IfLet {
            pattern: pattern, pattern_plan: pattern_plan, bindings: bindings,
            expr: remap_hir_handled_evidence(expr, sources, targets),
            then_block: remap_hir_handled_evidence(
                then_block, sources, targets),
            else_block: else_block.map(fn(value) {
                remap_hir_handled_evidence(value, sources, targets)
            }), span: span
        },
        HStmt::Drop {
            name, def_id, slot, place_target, site, reason, ty, span
        } =>
            HStmt::Drop { name: name, def_id: def_id, slot: slot,
                place_target: place_target.map(fn(value) {
                    remap_hir_handled_evidence(value, sources, targets)
                }), site: site, reason: reason, ty: ty, span: span }
    }
}

pub fn remap_hir_handled_evidence(
    value: HExpr, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> HExpr {
    match value {
        HExpr::IntLit { value, ty, effects, span } => HExpr::IntLit {
            value: value, ty: ty, effects: effects, span: span },
        HExpr::FloatLit { value, ty, effects, span } => HExpr::FloatLit {
            value: value, ty: ty, effects: effects, span: span },
        HExpr::StrLit { value, ty, effects, span } => HExpr::StrLit {
            value: value, ty: ty, effects: effects, span: span },
        HExpr::BoolLit { value, ty, effects, span } => HExpr::BoolLit {
            value: value, ty: ty, effects: effects, span: span },
        HExpr::Ident { name, resolved_name, def_id, source_slot,
                       callee_identity, dict_closure_dicts,
                       ty, effects, span } => HExpr::Ident {
            name: name, resolved_name: resolved_name, def_id: def_id,
            source_slot: source_slot, callee_identity: callee_identity,
            dict_closure_dicts: dict_closure_dicts,
            ty: ty, effects: effects, span: span
        },
        HExpr::BinOp { op, left, right, eq_dispatch, ord_dispatch,
                       eq_plan, ord_plan, ty, effects, span } => HExpr::BinOp {
            op: op,
            left: remap_hir_handled_evidence(left, sources, targets),
            right: remap_hir_handled_evidence(right, sources, targets),
            eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
            eq_plan: eq_plan, ord_plan: ord_plan,
            ty: ty, effects: effects, span: span
        },
        HExpr::UnaryOp { op, operand, ty, effects, span } => HExpr::UnaryOp {
            op: op,
            operand: remap_hir_handled_evidence(
                operand, sources, targets),
            ty: ty, effects: effects, span: span
        },
        HExpr::Call {
            callee, args, type_args, resolved_dicts, handled_evidence,
            callee_ref, method_ref, system_host, ty, effects, span
        } => {
            let mut remapped_args: List<HExpr> = []
            for arg in args {
                remapped_args.push(remap_hir_handled_evidence(
                    arg, sources, targets))
            }
            HExpr::Call {
                callee: remap_hir_handled_evidence(
                    callee, sources, targets),
                args: remapped_args, type_args: type_args,
                resolved_dicts: resolved_dicts,
                handled_evidence: remap_h_handled_evidence_refs(
                    handled_evidence, sources, targets),
                callee_ref: callee_ref, method_ref: method_ref,
                system_host: system_host,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::FieldAccess {
            receiver, field, access_kind, projection, ty, effects, span
        } => HExpr::FieldAccess {
            receiver: remap_hir_handled_evidence(
                receiver, sources, targets),
            field: field, access_kind: access_kind, projection: projection,
            ty: ty, effects: effects, span: span
        },
        HExpr::StructLit {
            name, owner_ref, type_args, fields: field_values, spread, constructor,
            ty, effects, span
        } => {
            let mut remapped_fields: List<HNominalStructFieldInit> = []
            for field in field_values {
                remapped_fields.push(HNominalStructFieldInit {
                    name: field.name, field_ref: field.field_ref,
                    field_index: field.field_index,
                    value: remap_hir_handled_evidence(
                        field.value, sources, targets)
                })
            }
            HExpr::StructLit {
                name: name, owner_ref: owner_ref, type_args: type_args,
                fields: remapped_fields,
                spread: spread.map(fn(value) {
                    remap_hir_handled_evidence(value, sources, targets)
                }),
                constructor: constructor,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::NamedVariantConstruct {
            enum_name, variant_name, variant_ref, fields: field_values, spread,
            constructor, ty, effects, span
        } => {
            let mut remapped_fields: List<HStructFieldInit> = []
            for field in field_values {
                remapped_fields.push(HStructFieldInit {
                    name: field.name, field_ref: field.field_ref,
                    value: remap_hir_handled_evidence(
                        field.value, sources, targets)
                })
            }
            HExpr::NamedVariantConstruct {
                enum_name: enum_name, variant_name: variant_name,
                variant_ref: variant_ref, fields: remapped_fields,
                spread: spread.map(fn(value) {
                    remap_hir_handled_evidence(value, sources, targets)
                }), constructor: constructor,
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::MatchExpr { scrutinee, arms, ty, effects, span } =>
            HExpr::MatchExpr {
                scrutinee: remap_hir_handled_evidence(
                    scrutinee, sources, targets),
                arms: remap_h_match_arms(arms, sources, targets),
                ty: ty, effects: effects, span: span
            },
        HExpr::Block { stmts, tail, ty, effects, span } => {
            let mut remapped_stmts: List<HStmt> = []
            for stmt in stmts {
                remapped_stmts.push(remap_h_stmt_handled_evidence(
                    stmt, sources, targets))
            }
            HExpr::Block {
                stmts: remapped_stmts,
                tail: tail.map(fn(value) {
                    remap_hir_handled_evidence(value, sources, targets)
                }), ty: ty, effects: effects, span: span
            }
        },
        HExpr::IfExpr {
            condition, then_branch, else_branch, ty, effects, span
        } => HExpr::IfExpr {
            condition: remap_hir_handled_evidence(
                condition, sources, targets),
            then_branch: remap_hir_handled_evidence(
                then_branch, sources, targets),
            else_branch: else_branch.map(fn(value) {
                remap_hir_handled_evidence(value, sources, targets)
            }), ty: ty, effects: effects, span: span
        },
        HExpr::StringInterp { parts, plan, ty, effects, span } => {
            let mut remapped_parts: List<HStringInterpPart> = []
            for part in parts {
                match part {
                    HStringInterpPart::Literal(text) =>
                        remapped_parts.push(HStringInterpPart::Literal(text)),
                    HStringInterpPart::Expression(expr) =>
                        remapped_parts.push(HStringInterpPart::Expression(
                            remap_hir_handled_evidence(
                                expr, sources, targets)))
                }
            }
            HExpr::StringInterp {
                parts: remapped_parts,
                plan: plan.map(fn(value) {
                    remap_h_string_interp_handled_evidence(
                        value, sources, targets)
                }), ty: ty, effects: effects, span: span
            }
        },
        HExpr::TryCatch { body, arms, ty, effects, span } => HExpr::TryCatch {
            body: remap_hir_handled_evidence(body, sources, targets),
            arms: remap_h_match_arms(arms, sources, targets),
            ty: ty, effects: effects, span: span
        },
        HExpr::HandleExpr {
            body, handlers, installed_evidence, ty, effects, span
        } => {
            let mut remapped_handlers: List<HEffectHandler> = []
            for handler in handlers {
                remapped_handlers.push(HEffectHandler {
                    effect_name: handler.effect_name,
                    handled_ref: handler.handled_ref,
                    operation_ref: handler.operation_ref,
                    fail_ref: handler.fail_ref,
                    executable_ref: handler.executable_ref,
                    captures: remap_h_lambda_captures(
                        handler.captures, sources, targets),
                    handled_evidence_bindings:
                        remap_h_handled_evidence_refs(
                            handler.handled_evidence_bindings,
                            sources, targets),
                    evidence_captures: remap_h_evidence_captures(
                        handler.evidence_captures, sources, targets),
                    op_name: handler.op_name, params: handler.params,
                    resume_binding: handler.resume_binding,
                    body: remap_hir_handled_evidence(
                        handler.body, sources, targets)
                })
            }
            HExpr::HandleExpr {
                body: remap_hir_handled_evidence(body, sources, targets),
                handlers: remapped_handlers,
                installed_evidence: remap_h_handled_evidence_refs(
                    installed_evidence, sources, targets),
                ty: ty, effects: effects, span: span
            }
        },
        HExpr::Lambda {
            executable_ref, params, captures, handled_evidence_bindings,
            evidence_captures, return_type, body, ty, effects, span
        } => HExpr::Lambda {
            executable_ref: executable_ref, params: params,
            captures: remap_h_lambda_captures(captures, sources, targets),
            handled_evidence_bindings: remap_h_handled_evidence_refs(
                handled_evidence_bindings, sources, targets),
            evidence_captures: remap_h_evidence_captures(
                evidence_captures, sources, targets),
            return_type: return_type,
            body: remap_hir_handled_evidence(body, sources, targets),
            ty: ty, effects: effects, span: span
        },
        HExpr::EffectOp {
            effect_name, op_name, operation_ref, fail_ref,
            handled_evidence, args, ty, effects, span
        } => {
            let mut remapped_args: List<HExpr> = []
            for arg in args {
                remapped_args.push(remap_hir_handled_evidence(
                    arg, sources, targets))
            }
            HExpr::EffectOp {
                effect_name: effect_name, op_name: op_name,
                operation_ref: operation_ref, fail_ref: fail_ref,
                handled_evidence: remap_h_handled_evidence_refs(
                    handled_evidence, sources, targets),
                args: remapped_args, ty: ty, effects: effects, span: span
            }
        },
        HExpr::RangeExpr {
            start, end, inclusive, constructor, ty, effects, span
        } => HExpr::RangeExpr {
            start: remap_hir_handled_evidence(start, sources, targets),
            end: remap_hir_handled_evidence(end, sources, targets),
            inclusive: inclusive, constructor: constructor,
            ty: ty, effects: effects, span: span
        },
        HExpr::ListLit { elements, constructor, ty, effects, span } => {
            let mut remapped: List<HExpr> = []
            for element in elements {
                remapped.push(remap_hir_handled_evidence(
                    element, sources, targets))
            }
            HExpr::ListLit { elements: remapped, constructor: constructor,
                ty: ty, effects: effects, span: span }
        },
        HExpr::TupleLit { elements, constructor, ty, effects, span } => {
            let mut remapped: List<HExpr> = []
            for element in elements {
                remapped.push(remap_hir_handled_evidence(
                    element, sources, targets))
            }
            HExpr::TupleLit { elements: remapped, constructor: constructor,
                ty: ty, effects: effects, span: span }
        },
        HExpr::IndexExpr {
            receiver, index, call_plan, projection, ty, effects, span
        } => HExpr::IndexExpr {
            receiver: remap_hir_handled_evidence(
                receiver, sources, targets),
            index: remap_hir_handled_evidence(index, sources, targets),
            call_plan: call_plan.map(fn(value) {
                remap_h_exact_call_handled_evidence(
                    value, sources, targets)
            }), projection: projection,
            ty: ty, effects: effects, span: span
        },
        HExpr::DictConstruct { base_dict, plan, inner, ty, effects, span } =>
            HExpr::DictConstruct { base_dict: base_dict, plan: plan,
                inner: inner, ty: ty, effects: effects, span: span },
        HExpr::Clone { inner, ty, effects, span } => HExpr::Clone {
            inner: remap_hir_handled_evidence(inner, sources, targets),
            ty: ty, effects: effects, span: span
        },
        HExpr::Take {
            source, source_slot, saved_slot, site, ty, effects, span
        } => HExpr::Take {
            source: remap_hir_handled_evidence(source, sources, targets),
            source_slot: source_slot, saved_slot: saved_slot, site: site,
            ty: ty, effects: effects, span: span
        },
        HExpr::ReturnExpr { value, ty, effects, span } => HExpr::ReturnExpr {
            value: value.map(fn(expr) {
                remap_hir_handled_evidence(expr, sources, targets)
            }), ty: ty, effects: effects, span: span
        },
        HExpr::UnsafeBlock { body, ty, effects, span } => HExpr::UnsafeBlock {
            body: remap_hir_handled_evidence(body, sources, targets),
            ty: ty, effects: effects, span: span
        }
    }
}

// Definition identity is a cross-pass invariant.  Validate immediately after
// synthetic lowering and again after RC insertion so a missing/colliding slot
// cannot degrade into a backend spelling lookup.
pub fn validate_hir_binder_def_ids(program: HProgram) {
    let mut seen: Set<Int> = set_new()
    validate_hir_decls(program.decls, seen)
}

struct HirValidationScope {
    names: List<Str>,
    def_ids: List<Int>,
    frames: List<Int>
}

fn new_hir_validation_scope() -> HirValidationScope {
    HirValidationScope { names: [], def_ids: [], frames: [] }
}

fn push_hir_validation_scope(mut scope: HirValidationScope) {
    scope.frames.push(scope.names.len())
}

fn pop_hir_validation_scope(mut scope: HirValidationScope) {
    let base = match scope.frames.pop() { some(value) => value, none => 0 }
    while scope.names.len() > base {
        scope.names.pop()
        scope.def_ids.pop()
    }
}

fn bind_hir_validation_scope(
    mut scope: HirValidationScope, name: Str, def_id: Int
) {
    scope.names.push(name)
    scope.def_ids.push(def_id)
}

fn hir_validation_name_index(scope: HirValidationScope, name: Str) -> Int {
    let mut index = scope.names.len() - 1
    while index >= 0 {
        if scope.names[index] == name { return index }
        index = index - 1
    }
    0 - 1
}

fn hir_validation_def_id_index(
    scope: HirValidationScope, def_id: Int
) -> Int {
    let mut index = scope.def_ids.len() - 1
    while index >= 0 {
        if scope.def_ids[index] == def_id { return index }
        index = index - 1
    }
    0 - 1
}

fn validate_hir_local_reference(
    scope: HirValidationScope, name: Str, def_id: Int?, label: Str
) {
    let name_index = hir_validation_name_index(scope, name)
    match def_id {
        some(id) => {
            let id_index = hir_validation_def_id_index(scope, id)
            if id_index >= 0 && scope.names[id_index] != name {
                panic("HIR ${label} DefId ${id} names '${scope.names[id_index]}', not '${name}'")
            }
            if name_index >= 0 && scope.def_ids[name_index] != id {
                panic("HIR ${label} '${name}' has mismatched DefId ${id}; visible slot is ${scope.def_ids[name_index]}")
            }
        },
        none => if name_index >= 0 {
            panic("HIR ${label} local reference '${name}' has no exact DefId")
        }
    }
}

fn validate_hir_drop_reference(
    scope: HirValidationScope, name: Str, def_id: Int
) {
    let id_index = hir_validation_def_id_index(scope, def_id)
    if id_index < 0 {
        panic("HIR Drop '${name}' references out-of-scope DefId ${def_id}")
    }
    if scope.names[id_index] != name {
        panic("HIR Drop DefId ${def_id} names '${scope.names[id_index]}', not '${name}'")
    }
}

fn validate_hir_binder(mut seen: Set<Int>, def_id: Int, label: Str) {
    if seen.contains(def_id) {
        panic("HIR binder DefId collision ${def_id} at ${label}")
    }
    seen.insert(def_id)
}

fn required_hir_def_id(def_id: Int?, label: Str) -> Int {
    match def_id {
        some(id) => id,
        none => panic("HIR ${label} has no exact DefId")
    }
}

fn validate_hir_params(
    params: List<HParam>, mut seen: Set<Int>,
    mut scope: HirValidationScope, label: Str
) {
    for param in params {
        let id = required_hir_def_id(
            param.def_id, "${label} parameter '${param.name}'")
        validate_hir_binder(seen, id,
            "${label} parameter '${param.name}'")
        bind_hir_validation_scope(scope, param.name, id)
    }
}

fn collect_hir_pattern_names(pattern: Pattern, mut names: Set<Str>) {
    match pattern {
        Pattern::Binding { name, .. } => {
            if name != "_" { names.insert(name) }
        },
        Pattern::Constructor { fields: field_values, .. } => {
            for field in field_values { collect_hir_pattern_names(field, names) }
        },
        Pattern::NamedConstructor { fields: field_values, .. } => {
            for field in field_values {
                collect_hir_pattern_names(field.pattern, names)
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            for element in elements {
                collect_hir_pattern_names(element, names)
            }
        },
        Pattern::OrPattern { patterns, .. } => {
            for alternative in patterns {
                collect_hir_pattern_names(alternative, names)
            }
        },
        Pattern::Wildcard { .. } | Pattern::Literal { .. } => {}
    }
}

fn validate_hir_pattern_bindings(
    pattern: Pattern, bindings: List<HPatternBinding>,
    mut seen: Set<Int>, mut scope: HirValidationScope, label: Str
) {
    let mut pattern_names: Set<Str> = set_new()
    collect_hir_pattern_names(pattern, pattern_names)
    let mut metadata_names: Set<Str> = set_new()
    for binding in bindings {
        if !pattern_names.contains(binding.name) {
            panic("HIR ${label} metadata names non-binding '${binding.name}'")
        }
        if metadata_names.contains(binding.name) {
            panic("HIR ${label} repeats binding metadata for '${binding.name}'")
        }
        metadata_names.insert(binding.name)
        if !slot_ref_is_source(binding.slot) ||
           !slot_ref_source_domain_is_lexical(binding.slot) ||
           slot_ref_source_def_id(binding.slot) != binding.def_id {
            panic("HIR ${label} binding SlotRef/DefId differs")
        }
        validate_hir_binder(seen, binding.def_id,
            "${label} binding '${binding.name}'")
        bind_hir_validation_scope(scope, binding.name, binding.def_id)
    }
    for name in pattern_names {
        if !metadata_names.contains(name) {
            panic("HIR ${label} binding '${name}' has no exact metadata")
        }
    }
}

fn validate_hir_arm(
    arm: HMatchArm, mut seen: Set<Int>,
    mut scope: HirValidationScope, label: Str
) {
    if arm.pattern_plan.is_none() {
        panic("HIR ${label} has no typed PatternPlan")
    }
    push_hir_validation_scope(scope)
    validate_hir_pattern_bindings(
        arm.pattern, arm.bindings, seen, scope, label)
    match arm.guard {
        some(guard) => validate_hir_expr(guard, seen, scope),
        none => {}
    }
    validate_hir_expr(arm.body, seen, scope)
    pop_hir_validation_scope(scope)
}

fn validate_hir_local_binding(
    name: Str, def_id: Int?, init: HExpr,
    mut seen: Set<Int>, mut scope: HirValidationScope
) {
    validate_hir_expr(init, seen, scope)
    if name != "_" {
        let id = required_hir_def_id(
            def_id, "local binding '${name}'")
        validate_hir_binder(seen, id, "local binding '${name}'")
        bind_hir_validation_scope(scope, name, id)
    }
}

fn validate_hir_stmt(
    stmt: HStmt, mut seen: Set<Int>, mut scope: HirValidationScope
) {
    match stmt {
        HStmt::Let { name, def_id, init, .. } =>
            validate_hir_local_binding(
                name, def_id, init, seen, scope),
        HStmt::Var { name, def_id, init, .. } =>
            validate_hir_local_binding(
                name, def_id, init, seen, scope),
        HStmt::Assign { target, value, .. } => {
            validate_hir_expr(target, seen, scope)
            validate_hir_expr(value, seen, scope)
        },
        HStmt::ExprStmt { expr, .. } =>
            validate_hir_expr(expr, seen, scope),
        HStmt::Return { value, .. } => match value {
            some(expr) => validate_hir_expr(expr, seen, scope),
            none => {}
        },
        HStmt::While { condition, body, .. } => {
            validate_hir_expr(condition, seen, scope)
            validate_hir_expr(body, seen, scope)
        },
        HStmt::ForIn { binding, def_id, destructure, plan,
                       iterable, body, .. } => {
            if plan.is_none() {
                panic("HIR ForIn: exact protocol plan is absent")
            }
            validate_hir_expr(iterable, seen, scope)
            push_hir_validation_scope(scope)
            match destructure {
                some(bindings) => {
                    for binding_ in bindings {
                        if binding_.name != "_" {
                            let id = required_hir_def_id(binding_.def_id,
                                "for destructure binding '${binding_.name}'")
                            validate_hir_binder(seen, id,
                                "for destructure binding '${binding_.name}'")
                            bind_hir_validation_scope(
                                scope, binding_.name, id)
                        }
                    }
                },
                none => if binding != "_" {
                    let id = required_hir_def_id(
                        def_id, "for binding '${binding}'")
                    validate_hir_binder(
                        seen, id, "for binding '${binding}'")
                    bind_hir_validation_scope(scope, binding, id)
                }
            }
            validate_hir_expr(body, seen, scope)
            pop_hir_validation_scope(scope)
        },
        HStmt::LetDestructure { pattern_plan, bindings, init, .. } => {
            if pattern_plan.is_none() {
                panic("HIR destructure has no typed PatternPlan")
            }
            validate_hir_expr(init, seen, scope)
            for binding in bindings {
                if binding.name != "_" {
                    let id = required_hir_def_id(binding.def_id,
                        "destructure binding '${binding.name}'")
                    validate_hir_binder(seen, id,
                        "destructure binding '${binding.name}'")
                    match binding.slot {
                        some(slot) => if !slot_ref_is_source(slot) ||
                                slot_ref_source_def_id(slot) != id {
                            panic("HIR destructure SlotRef/DefId differs")
                        },
                        none => panic("HIR destructure binding has no SlotRef")
                    }
                    bind_hir_validation_scope(scope, binding.name, id)
                }
            }
        },
        HStmt::IfLet { pattern, pattern_plan, bindings, expr,
                       then_block, else_block, .. } => {
            if pattern_plan.is_none() {
                panic("HIR if-let has no typed PatternPlan")
            }
            validate_hir_expr(expr, seen, scope)
            push_hir_validation_scope(scope)
            validate_hir_pattern_bindings(
                pattern, bindings, seen, scope, "if-let pattern")
            validate_hir_expr(then_block, seen, scope)
            pop_hir_validation_scope(scope)
            match else_block {
                some(block) => validate_hir_expr(block, seen, scope),
                none => {}
            }
        },
        HStmt::Drop { name, def_id, slot, place_target, .. } => {
            if slot_ref_is_source(slot) &&
               slot_ref_source_def_id(slot) != def_id {
                panic("HIR Drop: source SlotRef/DefId relation drifted")
            }
            validate_hir_drop_reference(scope, name, def_id)
            match place_target {
                some(target) => validate_hir_expr(target, seen, scope),
                none => {}
            }
        },
        HStmt::Break { .. } | HStmt::Continue { .. } => {}
    }
}

fn validate_hir_field_values(
    field_values: List<HStructFieldInit>, spread: HExpr?,
    mut seen: Set<Int>, mut scope: HirValidationScope
) {
    for field in field_values {
        validate_hir_expr(field.value, seen, scope)
    }
    match spread {
        some(value) => validate_hir_expr(value, seen, scope),
        none => {}
    }
}

fn validate_hir_variant_field_values(
    variant_ref: VariantRef, field_values: List<HStructFieldInit>, spread: HExpr?,
    mut seen: Set<Int>, mut scope: HirValidationScope
) {
    let mut field_indices: Set<Int> = set_new()
    for field in field_values {
        if !variant_ref_same(
                variant_field_ref_variant(field.field_ref), variant_ref) ||
           field_indices.contains(variant_field_ref_index(field.field_ref)) {
            panic("HIR identity: variant literal field relation drifted")
        }
        field_indices.insert(variant_field_ref_index(field.field_ref))
        validate_hir_expr(field.value, seen, scope)
    }
    match spread {
        some(value) => validate_hir_expr(value, seen, scope),
        none => {}
    }
}

fn validate_hir_nominal_field_values(
    name: Str, owner_ref: RegisteredNominalRef,
    field_values: List<HNominalStructFieldInit>, spread: HExpr?,
    mut seen: Set<Int>, mut scope: HirValidationScope
) {
    if registered_nominal_ref_display_name(owner_ref) != name {
        panic("HIR identity: struct literal nominal name drifted")
    }
    for field in field_values {
        if !symbol_ref_same(
                registered_nominal_ref_symbol(owner_ref),
                nominal_field_ref_owner(field.field_ref)) ||
           field.name != nominal_field_ref_name(field.field_ref) ||
           field.field_index != nominal_field_ref_index(field.field_ref) {
            panic("HIR identity: struct literal field owner drifted")
        }
        validate_hir_expr(field.value, seen, scope)
    }
    match spread {
        some(value) => validate_hir_expr(value, seen, scope),
        none => {}
    }
}

fn validate_hir_field_access_kind(
    kind: HFieldAccessKind, projection: HProjectionRef?,
    receiver: HExpr, field: Str
) {
    match kind {
        HFieldAccessKind::NominalField {
            owner_ref, field_ref, field_index } => {
            if !symbol_ref_same(
                    registered_nominal_ref_symbol(owner_ref),
                    nominal_field_ref_owner(field_ref)) ||
               field != nominal_field_ref_name(field_ref) ||
               field_index != nominal_field_ref_index(field_ref) {
                panic("HIR identity: nominal field owner relation drifted")
            }
            match projection {
                some(exact) => if h_projection_kind(exact) != 0 ||
                        !nominal_field_ref_same(
                            h_projection_nominal(exact), field_ref) {
                    panic("HIR identity: nominal projection drifted")
                },
                none => panic("HIR identity: nominal projection is absent")
            }
            match hexpr_type(receiver) {
                Type::StructType { name, .. } => {
                    if name != registered_nominal_ref_display_name(owner_ref) {
                        panic("HIR identity: nominal field receiver drifted")
                    }
                },
                _ => panic("HIR identity: nominal field has non-struct receiver")
            }
        },
        HFieldAccessKind::RecordField => {
            match projection {
                some(exact) => if h_projection_kind(exact) != 2 {
                    panic("HIR identity: record projection kind drifted")
                },
                none => panic("HIR identity: record projection is absent")
            }
            match hexpr_type(receiver) {
            Type::RecordType { .. } => {},
            _ => panic("HIR identity: record field has non-record receiver")
            }
        },
        HFieldAccessKind::TupleField => {
            match projection {
                some(exact) => if h_projection_kind(exact) != 3 {
                    panic("HIR identity: tuple projection kind drifted")
                },
                none => panic("HIR identity: tuple projection is absent")
            }
            match hexpr_type(receiver) {
            Type::TupleType { .. } => {},
            _ => panic("HIR identity: tuple field has non-tuple receiver")
            }
        },
        HFieldAccessKind::Method => if projection.is_some() {
            panic("HIR identity: method access carries projection")
        },
        HFieldAccessKind::ErrorRecovery =>
            panic("HIR identity: ErrorRecovery field access reached successful HIR")
    }
}

fn validate_hir_expr_values(
    values: List<HExpr>, mut seen: Set<Int>, mut scope: HirValidationScope
) {
    for value in values {
        validate_hir_expr(value, seen, scope)
    }
}

fn handled_requirements(row: EffectRow) -> List<HandledEffectRef> {
    let mut result: List<HandledEffectRef> = []
    for atom in row.effects {
        match atom {
            Effect::CustomEffect { reference, .. } => if !result.any(
                    fn(existing) {
                        handled_effect_ref_same(existing, reference)
                    }) {
                result.push(reference)
            },
            _ => {}
        }
    }
    result
}

fn validate_handled_evidence_uses(
    row: EffectRow, values: List<HandledEvidenceRef>, label: Str
) {
    let required = handled_requirements(row)
    if required.len() != values.len() {
        panic("HIR ${label}: handled evidence arity differs")
    }
    for index in 0..required.len() {
        if !handled_effect_ref_same(
                required.get(index).unwrap(),
                handled_evidence_requirement(values.get(index).unwrap())) {
            panic("HIR ${label}: handled evidence order differs")
        }
    }
}

fn validate_callable_handled_bindings(
    row: EffectRow, values: List<HandledEvidenceRef>,
    owner: ExecutableRef, label: Str
) {
    validate_handled_evidence_uses(row, values, label)
    for index in 0..values.len() {
        let value = values.get(index).unwrap()
        if !executable_ref_same(
                handled_evidence_contract_owner(value), owner) ||
           handled_evidence_ordinal(value) != index {
            panic("HIR ${label}: handled evidence owner/ordinal differs")
        }
    }
}

fn validate_hir_expr(
    expr: HExpr, mut seen: Set<Int>, mut scope: HirValidationScope
) {
    match expr {
        HExpr::Ident { name, def_id, source_slot, callee_identity, .. } => {
            validate_hir_local_reference(scope, name, def_id, "Ident")
            match source_slot {
                some(slot) => {
                    if !slot_ref_is_source(slot) ||
                       !slot_ref_source_domain_is_lexical(slot) {
                        panic("HIR Ident: source slot is not lexical")
                    }
                    match def_id {
                        some(id) => if slot_ref_source_def_id(slot) != id {
                            panic("HIR Ident: source SlotRef/DefId differs")
                        },
                        none => panic("HIR Ident: source slot has no DefId")
                    }
                },
                none => {}
            }
            match callee_identity {
                some(callee) => {
                    if callee_ref_is_local(callee) {
                        match source_slot {
                            some(slot) => if !slot_ref_same(
                                    callee_ref_local_slot(callee), slot) {
                                panic("HIR Ident: local CalleeRef/SlotRef differs")
                            },
                            none => panic(
                                "HIR Ident: local CalleeRef has no source slot")
                        }
                    } else if !callee_ref_is_named(callee) {
                        panic("HIR Ident: dynamic CalleeRef crossed TypedHIR")
                    }
                },
                none => {}
            }
        },
        HExpr::BinOp { op, left, right, eq_plan, ord_plan, .. } => {
            match op {
                BinOp::Eq | BinOp::Neq => if eq_plan.is_none() {
                    panic("HIR BinOp: Eq/Neq lacks exact operator plan")
                },
                BinOp::Lt | BinOp::Lte | BinOp::Gt | BinOp::Gte =>
                    if ord_plan.is_none() {
                        panic("HIR BinOp: ordering lacks exact operator plan")
                    },
                _ => if eq_plan.is_some() || ord_plan.is_some() {
                    panic("HIR BinOp: non-trait operator carries method plan")
                }
            }
            validate_hir_expr(left, seen, scope)
            validate_hir_expr(right, seen, scope)
        },
        HExpr::UnaryOp { operand, .. } =>
            validate_hir_expr(operand, seen, scope),
        HExpr::Call { callee, args, handled_evidence,
                      callee_ref, method_ref, system_host,
                      effects, .. } => {
            if callee_ref.is_some() && method_ref.is_some() {
                panic("HIR call: ordinary and method identities overlap")
            }
            match callee {
                HExpr::Ident { def_id: some(_), .. } => {
                    if method_ref.is_none() && callee_ref.is_none() {
                        panic("HIR call: exact Ident callee has no CalleeRef")
                    }
                },
                _ => {}
            }
            let callable_effects = match method_ref {
                some(method) => match method_call_ref_signature(method) {
                    Type::FnType { effects, .. } => effects,
                    _ => panic("HIR call: method signature is not callable")
                },
                none => match hexpr_type(callee) {
                    Type::FnType { effects, .. } => effects,
                    _ => panic("HIR call: callee type is not callable")
                }
            }
            validate_handled_evidence_uses(
                callable_effects, handled_evidence, "call")
            match system_host {
                some(host) => {
                    if method_ref.is_some() {
                        panic("HIR system host call: method identity overlaps host call")
                    }
                    let exact_callee = match callee_ref {
                        some(reference) => reference,
                        none => panic(
                            "HIR system host call: exact CalleeRef is absent")
                    }
                    if !callee_ref_is_named(exact_callee) ||
                       !executable_ref_is_named(
                            system_host_callable_executable(host)) ||
                       !symbol_ref_same(
                            callee_ref_named_symbol(exact_callee),
                            executable_ref_named_symbol(
                                system_host_callable_executable(host))) {
                        panic("HIR system host call: callable identity drifted")
                    }
                    let expected_effect = system_host_callable_effect(host)
                    let mut found = false
                    for atom in effects.effects {
                        match atom {
                            Effect::SystemEffect { reference } => if
                                system_effect_ref_same(
                                    reference, expected_effect) {
                                found = true
                            },
                            _ => {}
                        }
                    }
                    if !found {
                        panic("HIR system host call: capability is absent")
                    }
                },
                none => {}
            }
            match callee {
                HExpr::FieldAccess {
                    access_kind: HFieldAccessKind::Method, ty, ..
                } => match method_ref {
                    some(exact_method) => {
                        if !types_equal(
                                method_call_ref_signature(exact_method), ty) {
                            panic("HIR method call: exact signature drifted")
                        }
                    },
                    none => panic(
                        "HIR method call: Method callee has no exact identity")
                },
                _ => if method_ref.is_some() {
                    panic("HIR method call: exact identity has no Method callee")
                }
            }
            validate_hir_expr(callee, seen, scope)
            for arg in args { validate_hir_expr(arg, seen, scope) }
        },
        HExpr::FieldAccess { receiver, field, access_kind, projection, .. } => {
            validate_hir_field_access_kind(
                access_kind, projection, receiver, field)
            validate_hir_expr(receiver, seen, scope)
        },
        HExpr::StructLit {
            name, owner_ref, fields: field_values, spread, constructor, ..
        } => {
            let plan = match constructor {
                some(value) => value,
                none => panic("HIR struct literal: constructor plan is absent")
            }
            if h_constructor_kind(plan) != 2 ||
               h_constructor_fields(plan).len() != field_values.len() {
                panic("HIR struct literal: constructor field census differs")
            }
            validate_hir_nominal_field_values(
                name, owner_ref, field_values, spread, seen, scope)
        },
        HExpr::NamedVariantConstruct {
            variant_ref, fields: field_values, spread, constructor, ..
        } => {
            let plan = match constructor {
                some(value) => value,
                none => panic("HIR variant literal: constructor plan is absent")
            }
            if h_constructor_kind(plan) != 0 ||
               h_constructor_fields(plan).len() != field_values.len() ||
               !symbol_ref_same(
                    executable_ref_named_symbol(
                        h_constructor_executable(plan)),
                    variant_ref_member(variant_ref)) {
                panic("HIR variant literal: constructor identity differs")
            }
            validate_hir_variant_field_values(
                variant_ref, field_values, spread, seen, scope)
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            validate_hir_expr(scrutinee, seen, scope)
            for arm in arms {
                validate_hir_arm(arm, seen, scope, "match arm")
            }
        },
        HExpr::Block { stmts, tail, .. } => {
            push_hir_validation_scope(scope)
            for stmt in stmts { validate_hir_stmt(stmt, seen, scope) }
            match tail {
                some(value) => validate_hir_expr(value, seen, scope),
                none => {}
            }
            pop_hir_validation_scope(scope)
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            validate_hir_expr(condition, seen, scope)
            validate_hir_expr(then_branch, seen, scope)
            match else_branch {
                some(value) => validate_hir_expr(value, seen, scope),
                none => {}
            }
        },
        HExpr::StringInterp { parts, plan, .. } => {
            let exact = match plan {
                some(value) => value,
                none => panic("HIR string interpolation: exact plan is absent")
            }
            let mut expression_count = 0
            for part in parts {
                match part {
                    HStringInterpPart::Literal(_) => {},
                    HStringInterpPart::Expression(value) => {
                        expression_count = expression_count + 1
                        validate_hir_expr(value, seen, scope)
                    }
                }
            }
            if h_string_interp_value_to_string(exact).len() !=
                   expression_count {
                panic("HIR string interpolation: conversion census differs")
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            validate_hir_expr(body, seen, scope)
            for arm in arms {
                validate_hir_arm(arm, seen, scope, "catch arm")
            }
        },
        HExpr::HandleExpr { body, handlers, installed_evidence, .. } => {
            validate_hir_expr(body, seen, scope)
            let mut installed_requirements: List<HandledEffectRef> = []
            for handler in handlers {
                if executable_ref_is_named(handler.executable_ref) {
                    panic("HIR effect handler: handler body executable is named")
                }
                match (handler.handled_ref, handler.operation_ref,
                       handler.fail_ref) {
                    (some(effect_ref), some(operation_ref), none) => {
                        if !installed_requirements.any(fn(existing) {
                                handled_effect_ref_same(existing, effect_ref)
                            }) {
                            installed_requirements.push(effect_ref)
                        }
                        if !handled_effect_ref_same(
                                effect_ref,
                                effect_operation_ref_effect(operation_ref)) {
                            panic("HIR effect handler: operation/effect identity drifted")
                        }
                    },
                    (none, none, some(fail_ref)) => {
                        let _ = h_fail_operation_tag(fail_ref)
                    },
                    _ => panic("HIR effect handler: operation identity presence drifted")
                }
                validate_callable_handled_bindings(
                    hexpr_effects(handler.body),
                    handler.handled_evidence_bindings,
                    handler.executable_ref, "handler")
                for capture in handler.evidence_captures {
                    if !executable_ref_same(
                            handled_evidence_contract_owner(
                                handled_evidence_capture_target(capture)),
                            handler.executable_ref) {
                        panic("HIR handler: evidence capture target owner differs")
                    }
                }
                let label = "handler '${handler.effect_name}.${handler.op_name}'"
                push_hir_validation_scope(scope)
                validate_hir_params(handler.params, seen, scope, label)
                match handler.resume_binding {
                    some(binding) => {
                        validate_hir_binder(seen, binding.def_id,
                            "${label} resume binding '${binding.name}'")
                        bind_hir_validation_scope(
                            scope, binding.name, binding.def_id)
                    },
                    none => {}
                }
                validate_hir_expr(handler.body, seen, scope)
                pop_hir_validation_scope(scope)
            }
            if installed_requirements.len() != installed_evidence.len() {
                panic("HIR handle: installed evidence arity differs")
            }
            for index in 0..installed_requirements.len() {
                if !handled_effect_ref_same(
                        installed_requirements.get(index).unwrap(),
                        handled_evidence_requirement(
                            installed_evidence.get(index).unwrap())) {
                    panic("HIR handle: installed evidence order differs")
                }
            }
        },
        HExpr::Lambda { executable_ref, params, captures,
                        handled_evidence_bindings, evidence_captures,
                        body, ty, .. } => {
            let mut capture_index = 0
            while capture_index < captures.len() {
                let capture = captures.get(capture_index).unwrap()
                if slot_ref_same(capture.source, capture.target) {
                    panic("HIR lambda: invalid pre-resource capture relation")
                }
                let mut right = capture_index + 1
                while right < captures.len() {
                    let other = captures.get(right).unwrap()
                    if slot_ref_same(capture.source, other.source) ||
                       slot_ref_same(capture.target, other.target) {
                        panic("HIR lambda: duplicate capture relation")
                    }
                    right = right + 1
                }
                match capture.value {
                    some(value) => validate_hir_expr(value, seen, scope),
                    none => {}
                }
                capture_index = capture_index + 1
            }
            let lambda_effects = match ty {
                Type::FnType { effects, .. } => effects,
                _ => panic("HIR lambda: callable type is absent")
            }
            validate_callable_handled_bindings(
                lambda_effects, handled_evidence_bindings,
                executable_ref, "lambda")
            for capture in evidence_captures {
                if !executable_ref_same(
                        handled_evidence_contract_owner(
                            handled_evidence_capture_target(capture)),
                        executable_ref) {
                    panic("HIR lambda: evidence capture target owner differs")
                }
            }
            push_hir_validation_scope(scope)
            validate_hir_params(params, seen, scope, "lambda")
            validate_hir_expr(body, seen, scope)
            pop_hir_validation_scope(scope)
        },
        HExpr::EffectOp { operation_ref, fail_ref,
                          handled_evidence, args, .. } => {
            match (operation_ref, fail_ref) {
                (some(operation), none) => {
                    if handled_evidence.len() != 1 ||
                       !handled_effect_ref_same(
                            effect_operation_ref_effect(operation),
                            handled_evidence_requirement(
                                handled_evidence.get(0).unwrap())) {
                        panic("HIR identity: effect operation evidence differs")
                    }
                },
                (none, some(exact_fail)) => {
                    let _ = h_fail_operation_tag(exact_fail)
                    if handled_evidence.len() != 0 {
                        panic("HIR identity: fail operation carries handled evidence")
                    }
                },
                _ => panic("HIR identity: effect operation domain is ambiguous/absent")
            }
            for arg in args { validate_hir_expr(arg, seen, scope) }
        },
        HExpr::RangeExpr { start, end, constructor, .. } => {
            match constructor {
                some(plan) => if h_constructor_kind(plan) != 0 ||
                        h_constructor_fields(plan).len() != 3 {
                    panic("HIR Range: constructor field census differs")
                },
                none => panic("HIR Range: exact constructor is absent")
            }
            validate_hir_expr(start, seen, scope)
            validate_hir_expr(end, seen, scope)
        },
        HExpr::ListLit { elements, constructor, .. } => {
            match constructor {
                some(plan) => if h_constructor_kind(plan) != 0 ||
                        h_constructor_fields(plan).len() != elements.len() {
                    panic("HIR List: constructor field census differs")
                },
                none => panic("HIR List: exact constructor is absent")
            }
            validate_hir_expr_values(elements, seen, scope)
        },
        HExpr::TupleLit { elements, constructor, .. } => {
            match constructor {
                some(plan) => if h_constructor_kind(plan) != 1 ||
                        h_constructor_tuple_arity(plan) != elements.len() {
                    panic("HIR Tuple: constructor field census differs")
                },
                none => panic("HIR Tuple: exact constructor is absent")
            }
            validate_hir_expr_values(elements, seen, scope)
        },
        HExpr::IndexExpr { receiver, index, call_plan, projection, ty, .. } => {
            match ty {
                Type::ErrorType => {},
                _ => if call_plan.is_none() || projection.is_none() {
                    panic("HIR IndexExpr: exact call/projection plan is absent")
                }
            }
            validate_hir_expr(receiver, seen, scope)
            validate_hir_expr(index, seen, scope)
        },
        HExpr::Clone { inner, .. } =>
            validate_hir_expr(inner, seen, scope),
        HExpr::Take { source, source_slot, saved_slot, .. } => {
            match source {
                HExpr::Ident { def_id: some(id), .. } => {
                    if slot_ref_is_source(source_slot) &&
                       slot_ref_source_def_id(source_slot) != id {
                        panic("HIR Take: source SlotRef/DefId relation drifted")
                    }
                },
                _ => {}
            }
            match saved_slot {
                some(saved) => if slot_ref_same(source_slot, saved) {
                    panic("HIR Take: source and saved slots alias")
                },
                none => {}
            }
            validate_hir_expr(source, seen, scope)
        },
        HExpr::ReturnExpr { value, .. } => match value {
            some(inner) => validate_hir_expr(inner, seen, scope),
            none => {}
        },
        HExpr::UnsafeBlock { body, .. } =>
            validate_hir_expr(body, seen, scope),
        HExpr::DictConstruct { plan, .. } => if plan.is_none() {
            panic("HIR dictionary construct: exact plan is absent")
        },
        HExpr::IntLit { .. } | HExpr::FloatLit { .. } |
        HExpr::StrLit { .. } | HExpr::BoolLit { .. } => {}
    }
}

fn validate_hir_decls(decls: List<HDecl>, mut seen: Set<Int>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, def_id, executable_ref, impl_method_ref,
                        params, body, .. } => {
                if !executable_ref_is_named(executable_ref) {
                    panic("HIR identity: function executable is not named")
                }
                match impl_method_ref {
                    some(method_ref) => if !symbol_ref_same(
                            executable_ref_named_symbol(executable_ref),
                            impl_method_ref_member(method_ref)) {
                        panic("HIR identity: impl method executable drifted")
                    },
                    none => {}
                }
                match def_id {
                    some(id) => validate_hir_binder(
                        seen, id, "function '${name}'"),
                    none => {}
                }
                let mut scope = new_hir_validation_scope()
                validate_hir_params(
                    params, seen, scope, "function '${name}'")
                validate_hir_expr(body, seen, scope)
            },
            HDecl::Impl { owner_ref, provider_ref, trait_name, trait_ref,
                          delegate_plan, default_specializations,
                          methods, .. } => {
                let _ = impl_provider_kind_tag(
                    impl_provider_ref_kind(provider_ref))
                if trait_name.is_some() != trait_ref.is_some() {
                    panic("HIR identity: impl trait name/ref presence drifted")
                }
                if !impl_provider_ref_same(
                        impl_owner_ref_provider(owner_ref), provider_ref) {
                    panic("HIR identity: impl owner/provider drifted")
                }
                match (impl_owner_ref_trait(owner_ref), trait_ref) {
                    (some(a), some(b)) => if !symbol_ref_same(a, b) {
                        panic("HIR identity: impl owner/trait drifted")
                    },
                    (none, none) => {},
                    _ => panic("HIR identity: impl owner trait presence drifted")
                }
                match delegate_plan {
                    some(plan) => {
                        if !impl_owner_ref_same(
                                h_delegate_child_owner(plan), owner_ref) ||
                           !impl_provider_ref_same(
                                h_delegate_child_provider(plan), provider_ref) {
                            panic("HIR delegate plan: HDecl owner/provider differs")
                        }
                        match trait_ref {
                            some(exact_trait) => if !symbol_ref_same(
                                    h_delegate_trait(plan), exact_trait) {
                                panic("HIR delegate plan: HDecl trait differs")
                            },
                            none => panic("HIR delegate plan: inherent HDecl")
                        }
                    },
                    none => {}
                }
                for index in 0..default_specializations.len() {
                    let plan = default_specializations.get(index).unwrap()
                    if !impl_owner_ref_same(
                            h_default_specialization_owner(plan), owner_ref) {
                        panic("HIR default specialization: HDecl owner differs")
                    }
                    for right in index + 1..default_specializations.len() {
                        if impl_method_ref_same(
                                h_default_specialization_generated_method(plan),
                                h_default_specialization_generated_method(
                                    default_specializations.get(right).unwrap())) {
                            panic("HIR default specialization: method repeats")
                        }
                    }
                }
                validate_hir_decls(methods, seen)
            },
            HDecl::Enum { owner_ref, variants, .. } => {
                for variant_index in 0..variants.len() {
                    let variant = variants.get(variant_index).unwrap()
                    if variant_ref_source_index(variant.variant_ref) !=
                            variant_index ||
                       !registered_nominal_ref_same(
                            variant_ref_owner(variant.variant_ref), owner_ref) ||
                       variant.fields.len() != variant.field_refs.len() {
                        panic("HIR identity: enum variant relation drifted")
                    }
                    for field_index in 0..variant.field_refs.len() {
                        let field_ref = variant.field_refs.get(field_index).unwrap()
                        if variant_field_ref_index(field_ref) != field_index ||
                           !variant_ref_same(
                                variant_field_ref_variant(field_ref),
                                variant.variant_ref) {
                            panic("HIR identity: enum payload field relation drifted")
                        }
                    }
                }
            },
            HDecl::Effect { name, owner_ref, handled_ref, ops, .. } => {
                if owner_ref.is_some() != handled_ref.is_some() {
                    panic("HIR identity: effect owner/domain presence drifted")
                }
                for op_index in 0..ops.len() {
                    let op = ops.get(op_index).unwrap()
                    match (handled_ref, op.operation_ref) {
                        (some(effect_ref), some(operation_ref)) => {
                            if !handled_effect_ref_same(
                                    effect_operation_ref_effect(operation_ref),
                                    effect_ref) ||
                               effect_operation_ref_source_index(operation_ref) !=
                                    op_index {
                                panic("HIR identity: effect operation relation drifted")
                            }
                        },
                        (none, none) => {},
                        _ => panic("HIR identity: effect operation domain drifted")
                    }
                }
            },
            HDecl::Test { body, .. } => {
                let mut scope = new_hir_validation_scope()
                validate_hir_expr(body, seen, scope)
            },
            HDecl::Trait { name, owner_ref, methods, .. } => {
                if registered_trait_ref_display_name(owner_ref) != name {
                    panic("HIR identity: trait declaration owner drifted")
                }
                let mut previous_source_member_index = -1
                for method_index in 0..methods.len() {
                    let method = methods.get(method_index).unwrap()
                    let source_member_index =
                        trait_method_ref_source_member_index(method.method_ref)
                    if !symbol_ref_same(
                            trait_method_ref_trait(method.method_ref),
                            registered_trait_ref_symbol(owner_ref)) ||
                       trait_method_ref_callable_slot_index(
                            method.method_ref) != method_index ||
                       source_member_index < method_index ||
                       source_member_index <= previous_source_member_index ||
                       trait_method_ref_name(method.method_ref) != method.name {
                        panic("HIR identity: trait method relation drifted")
                    }
                    previous_source_member_index = source_member_index
                    if !executable_ref_is_named(method.executable_ref) ||
                       !symbol_ref_same(
                            executable_ref_named_symbol(method.executable_ref),
                            trait_method_ref_member(method.method_ref)) {
                        panic("HIR identity: trait method executable drifted")
                    }
                    if method.has_default != method.body.is_some() {
                        panic("HIR identity: trait default/body relation drifted")
                    }
                    match method.body {
                        some(body) => {
                            let mut scope = new_hir_validation_scope()
                            validate_hir_params(method.params, seen, scope,
                                "trait default '${name}.${method.name}'")
                            validate_hir_expr(body, seen, scope)
                        },
                        none => {}
                    }
                }
            },
            HDecl::Const { name, def_id, executable_ref, init, .. } => {
                if !executable_ref_is_named(executable_ref) {
                    panic("HIR identity: const executable is not named")
                }
                match def_id {
                    some(id) => validate_hir_binder(
                        seen, id, "const '${name}'"),
                    none => {}
                }
                let mut scope = new_hir_validation_scope()
                validate_hir_expr(init, seen, scope)
            },
            HDecl::ModBlock { decls: inner, .. } =>
                validate_hir_decls(inner, seen),
            HDecl::Struct {
                name, owner_ref, fields: field_values, ..
            } => {
                if registered_nominal_ref_display_name(owner_ref) != name {
                    panic("HIR identity: struct declaration name drifted")
                }
                for field_index in 0..field_values.len() {
                    match field_values.get(field_index) {
                        some(field) => {
                            if !symbol_ref_same(
                                    registered_nominal_ref_symbol(owner_ref),
                                    nominal_field_ref_owner(field.field_ref)) ||
                               nominal_field_ref_index(field.field_ref) != field_index ||
                               field.field_index != field_index ||
                               nominal_field_ref_name(field.field_ref) != field.name {
                                panic("HIR identity: struct field relation drifted")
                            }
                        },
                        none => {}
                    }
                }
            },
            HDecl::ExternFn { executable_ref, .. } => {
                if !executable_ref_is_named(executable_ref) {
                    panic("HIR identity: extern executable is not named")
                }
            },
            HDecl::Enum { .. } | HDecl::ExternType { .. } |
            HDecl::TypeAlias { .. } => {}
        }
    }
}

// B-102 R-clean (2026-06-07) — the A1 Type-DAG never-drop special case
// (is_type_dag_type_name / is_type_dag_type) is REMOVED.  Type and the
// structs/enums reachable from it now participate in ordinary Perceus RC:
// codegen_c generates a recursive ring_drop_T for them, perceus Clone-wraps
// every escaping owner-bearing Type substructure (so the shallow ring_dup is
// balanced by the deep recursive drop), and the working-set is reclaimed at
// scope end.  See design.md §7.11 "Type-DAG 内存回收：pure Perceus RC".

// Codegen naming conventions
pub fn variant_ctor_name(enum_name: Str, variant_name: Str) -> Str {
    "${enum_name}_${variant_name}"
}

// A fieldless user enum variant is represented by inference as an Ident whose
// resolved_name comes from exact DefId-keyed constructor provenance. Unlike an
// ordinary Ident read, evaluating that node CALLS the constructor and therefore
// produces a fresh owned enum box. Keep this cross-stage ownership fact in one
// place so Perceus and the post-RC verifier cannot disagree.
pub fn is_nullary_variant_ctor_ident(expr: HExpr) -> Bool {
    match expr {
        HExpr::Ident { resolved_name, ty, .. } => match resolved_name {
            some(rn) => match ty {
                Type::EnumType { name, .. } =>
                    // Option::none is the sole fieldless constructor whose
                    // codegen result is a borrowed never-drop runtime singleton
                    // rather than a fresh enum allocation. It still carries
                    // resolved_name so codegen can select ring_Option_none.
                    rn != variant_ctor_name(BUILTIN_OPTION, "none") &&
                    rn.starts_with(variant_ctor_name(name, "")),
                _ => false,
            },
            none => false,
        },
        _ => false,
    }
}

// An Ident carrying some(dicts) is not a borrow read: codegen allocates a fresh
// direct-ABI wrapper closure (some([]) is the explicit zero-bound marker).
// Control-flow wrappers preserve that fact only when every value-producing path
// yields the same fresh callable. Perceus and verify_rc share this predicate.
pub fn is_exact_direct_call_ident(expr: HExpr) -> Bool {
    match expr {
        HExpr::Ident {
            def_id: some(_), dict_closure_dicts: some(_), ..
        } => true,
        _ => false
    }
}

pub fn is_materialized_fn_value(expr: HExpr) -> Bool {
    match expr {
        HExpr::Ident { dict_closure_dicts, .. } => dict_closure_dicts.is_some(),
        HExpr::Block { tail, .. } => match tail {
            some(value) => is_materialized_fn_value(value),
            none => false
        },
        HExpr::IfExpr { then_branch, else_branch, .. } => match else_branch {
            some(value) =>
                is_materialized_fn_value(then_branch) &&
                is_materialized_fn_value(value),
            none => false
        },
        HExpr::MatchExpr { arms, .. } => {
            let mut all = arms.len() > 0
            for arm in arms {
                if is_materialized_fn_value(arm.body) == false { all = false }
            }
            all
        },
        _ => false
    }
}

pub fn trait_dict_name(type_name: Str, trait_name: Str) -> Str {
    let safe_type = if type_name.contains("::") { type_name.replace("::", "$") } else { type_name }
    let safe_trait = if trait_name.contains("::") { trait_name.replace("::", "$") } else { trait_name }
    "__${safe_type}_${safe_trait}"
}

pub fn trait_bound_param_name(type_param: Str, trait_name: Str) -> Str {
    let safe_trait = if trait_name.contains("::") { trait_name.replace("::", "$") } else { trait_name }
    "__ring_${type_param}_${safe_trait}"
}

pub fn default_method_self_name(type_name: Str) -> Str {
    "__ring_self_${type_name}"
}

// B-163 step 5 (plan §2.5 #2): trait dict SLOT ORDER is a cross-stage contract
// (dict emitters fill slot i, dispatch sites GEP slot i) — the single source
// lives HERE, not per-backend.  Both maps are derived from HDecl::Trait decls
// plus the built-in trait seeds; a backend must consume these instead of
// hardcoding its own registry (the LLVM backend's private scan_trait_decls
// predates this and is retired with the backend in B-163 Phase 2).
pub fn scan_trait_method_order(decls: List<HDecl>, mut trait_method_order: Map<Str, List<Str>>, mut trait_supertraits: Map<Str, List<Str>>) {
    for decl in decls {
        match decl {
            HDecl::Trait { name, methods, supertraits, .. } => {
                let mut method_names: List<Str> = []
                for m in methods {
                    method_names.push(m.name)
                }
                trait_method_order.insert(name, method_names)
                trait_supertraits.insert(name, supertraits)
            },
            HDecl::ModBlock { decls: md, .. } => {
                scan_trait_method_order(md, trait_method_order, trait_supertraits)
            },
            _ => {},
        }
    }
    // Built-in traits that never appear as HDecl::Trait.
    if trait_method_order.get("Eq").is_none() {
        trait_method_order.insert("Eq", ["eq", "ne"])
    }
    if trait_method_order.get("Clone").is_none() {
        trait_method_order.insert("Clone", ["clone"])
    }
    if trait_method_order.get("Ord").is_none() {
        trait_method_order.insert("Ord", ["cmp"])
    }
    if trait_method_order.get("Debug").is_none() {
        trait_method_order.insert("Debug", ["debug"])
    }
    if trait_method_order.get("Hash").is_none() {
        trait_method_order.insert("Hash", ["hash"])
    }
}

// Transitive supertrait closure in deterministic DFS order — the ORDER is a
// cross-stage contract too: default trait method functions take supertrait
// dicts as leading params in exactly this order (declarer and every caller
// must agree).
pub fn collect_all_supertraits(trait_supertraits: Map<Str, List<Str>>, trait_name: Str) -> List<Str> {
    let mut result: List<Str> = []
    let mut visited: Set<Str> = set_new()
    let mut stack: List<Str> = []
    match trait_supertraits.get(trait_name) {
        some(supers) => {
            for st in supers { stack.push(st) }
        },
        none => {},
    }
    while stack.len() > 0 {
        let current = stack.pop().unwrap()
        if visited.contains(current) { continue }
        visited.insert(current)
        result.push(current)
        match trait_supertraits.get(current) {
            some(parent_supers) => {
                for ps in parent_supers { stack.push(ps) }
            },
            none => {},
        }
    }
    result
}

pub const ENUM_TAG_FIELD: Str = "_tag"
pub const OPTION_SOME_TAG: Str = "some"
pub const OPTION_NONE_TAG: Str = "none"
pub const OPTION_PAYLOAD_FIELD: Str = "_0"
pub const RUNTIME_EFFECT_ABORT: Str = "__EffectAbort"
pub const RUNTIME_MATCH_FAIL: Str = "__match_fail"

pub fn hexpr_type(e: HExpr) -> Type {
    match e {
        HExpr::IntLit { ty, .. } => ty,
        HExpr::FloatLit { ty, .. } => ty,
        HExpr::StrLit { ty, .. } => ty,
        HExpr::BoolLit { ty, .. } => ty,
        HExpr::Ident { ty, .. } => ty,
        HExpr::BinOp { ty, .. } => ty,
        HExpr::UnaryOp { ty, .. } => ty,
        HExpr::Call { ty, .. } => ty,
        HExpr::FieldAccess { ty, .. } => ty,
        HExpr::StructLit { ty, .. } => ty,
        HExpr::NamedVariantConstruct { ty, .. } => ty,
        HExpr::MatchExpr { ty, .. } => ty,
        HExpr::Block { ty, .. } => ty,
        HExpr::IfExpr { ty, .. } => ty,
        HExpr::StringInterp { ty, .. } => ty,
        HExpr::TryCatch { ty, .. } => ty,
        HExpr::HandleExpr { ty, .. } => ty,
        HExpr::Lambda { ty, .. } => ty,
        HExpr::EffectOp { ty, .. } => ty,
        HExpr::RangeExpr { ty, .. } => ty,
        HExpr::ListLit { ty, .. } => ty,
        HExpr::TupleLit { ty, .. } => ty,
        HExpr::IndexExpr { ty, .. } => ty,
        HExpr::DictConstruct { ty, .. } => ty,
        HExpr::Clone { ty, .. } => ty,
        HExpr::Take { ty, .. } => ty,
        HExpr::ReturnExpr { ty, .. } => ty,
        HExpr::UnsafeBlock { ty, .. } => ty
    }
}

pub fn hexpr_effects(e: HExpr) -> EffectRow {
    match e {
        HExpr::IntLit { effects, .. } => effects,
        HExpr::FloatLit { effects, .. } => effects,
        HExpr::StrLit { effects, .. } => effects,
        HExpr::BoolLit { effects, .. } => effects,
        HExpr::Ident { effects, .. } => effects,
        HExpr::BinOp { effects, .. } => effects,
        HExpr::UnaryOp { effects, .. } => effects,
        HExpr::Call { effects, .. } => effects,
        HExpr::FieldAccess { effects, .. } => effects,
        HExpr::StructLit { effects, .. } => effects,
        HExpr::NamedVariantConstruct { effects, .. } => effects,
        HExpr::MatchExpr { effects, .. } => effects,
        HExpr::Block { effects, .. } => effects,
        HExpr::IfExpr { effects, .. } => effects,
        HExpr::StringInterp { effects, .. } => effects,
        HExpr::TryCatch { effects, .. } => effects,
        HExpr::HandleExpr { effects, .. } => effects,
        HExpr::Lambda { effects, .. } => effects,
        HExpr::EffectOp { effects, .. } => effects,
        HExpr::RangeExpr { effects, .. } => effects,
        HExpr::ListLit { effects, .. } => effects,
        HExpr::TupleLit { effects, .. } => effects,
        HExpr::IndexExpr { effects, .. } => effects,
        HExpr::DictConstruct { effects, .. } => effects,
        HExpr::Clone { effects, .. } => effects,
        HExpr::Take { effects, .. } => effects,
        HExpr::ReturnExpr { effects, .. } => effects,
        HExpr::UnsafeBlock { effects, .. } => effects
    }
}

pub fn hexpr_span(e: HExpr) -> Span {
    match e {
        HExpr::IntLit { span, .. } => span,
        HExpr::FloatLit { span, .. } => span,
        HExpr::StrLit { span, .. } => span,
        HExpr::BoolLit { span, .. } => span,
        HExpr::Ident { span, .. } => span,
        HExpr::BinOp { span, .. } => span,
        HExpr::UnaryOp { span, .. } => span,
        HExpr::Call { span, .. } => span,
        HExpr::FieldAccess { span, .. } => span,
        HExpr::StructLit { span, .. } => span,
        HExpr::NamedVariantConstruct { span, .. } => span,
        HExpr::MatchExpr { span, .. } => span,
        HExpr::Block { span, .. } => span,
        HExpr::IfExpr { span, .. } => span,
        HExpr::StringInterp { span, .. } => span,
        HExpr::TryCatch { span, .. } => span,
        HExpr::HandleExpr { span, .. } => span,
        HExpr::Lambda { span, .. } => span,
        HExpr::EffectOp { span, .. } => span,
        HExpr::RangeExpr { span, .. } => span,
        HExpr::ListLit { span, .. } => span,
        HExpr::TupleLit { span, .. } => span,
        HExpr::IndexExpr { span, .. } => span,
        HExpr::DictConstruct { span, .. } => span,
        HExpr::Clone { span, .. } => span,
        HExpr::Take { span, .. } => span,
        HExpr::ReturnExpr { span, .. } => span,
        HExpr::UnsafeBlock { span, .. } => span
    }
}

// ============================================================
// B-104 D1 built-in rule ① — extern-handle type-level RC exclusion (audit #139)
// ============================================================
//
// `extern type` declarations can describe opaque foreign handles: their values
// are raw pointers produced by a non-Ring allocator, with no ring_alloc RC
// header at ptr-8.
// ring_dup on one WRITES a refcount into foreign memory; ring_drop READS a
// garbage header and may free a foreign interior pointer — both corrupt the
// foreign heap.  Such values are therefore EXCLUDED from RC entirely, decided at
// the TYPE level rather than a name list that would drift as the FFI grows
// (2026-06-11 user decision, backlog B-104 D1 rule ①):
//   * never Clone   (rc_escape: escape = MOVE, no ring_dup)
//   * never Drop    (is_droppable_init: false → never enters the owned set)
//   * never materialise (anf_should_materialize: false → no __anf binding)
//
// The registry side: checker registers `extern type X` as
// `StructDef { fields: [], is_extern: true }` (infer_register.ring), and every
// use site resolves to `Type::StructType { name: X, .. }` carrying the SAME name
// as the `HDecl::ExternType` decl (bare for file-level decls; `${mod}::${name}`
// for inline-mod decls — check_mod_decl prefixes the decl BEFORE check_decl, so
// HIR decl name and StructType name agree in both forms).
//
// B-144: HProgram.extern_type_names carries the set of extern type names
// visible to this module.  In single-file mode, collect_extern_type_names
// (below) scans the HIR decls.  In multi-file mode, compiler_mod::compile_phases
// computes a per-module set that covers use-imported extern types without
// bare-name collisions (B-145: the old blind global union stamped module A's
// `extern type Foo` onto module B which had its own `struct Foo`, falsely
// RC-excluding B's Foo).

// Collect the extern type names declared by this module's HIR (recursing into
// inline mod blocks, whose decl names are already module-prefixed).
pub fn collect_extern_type_names(decls: List<HDecl>) -> Set<Str> {
    let mut out: Set<Str> = set_new()
    collect_extern_type_names_rec(decls, out)
    out
}

fn collect_extern_type_names_rec(decls: List<HDecl>, mut out: Set<Str>) {
    for d in decls {
        match d {
            HDecl::ExternType { name, .. } => { out.insert(name) },
            HDecl::ModBlock { decls: md, .. } => { collect_extern_type_names_rec(md, out) },
            _ => {},
        }
    }
}

// A type whose values ARE foreign handles (direct extern type).  ring_dup /
// ring_drop on such a value corrupts foreign memory — full RC exclusion.
pub fn is_extern_handle_type(ty: Type, externs: Set<Str>) -> Bool {
    if externs.len() == 0 {
        false
    } else {
        match ty {
            Type::StructType { name, .. } => externs.contains(name),
            _ => false,
        }
    }
}

// B-104 D1 rule ② (Unit) + rule ① (direct extern): a value of this type must
// never be Clone'd, never be Drop'ed, never enter the owned set, and never be
// materialised.  UnitType: the checker guarantees Unit has no value semantics
// (Unit has no value semantics); at the ABI level a Unit-typed call may
// accidentally return a live pointer (the receiver-returning mutators —
// `return list;` etc., see perceus.ring's B-103 classification table), so
// dup/drop bookkeeping on it is at best a pin-leak and at worst a UAF.
pub fn is_rc_excluded_type(ty: Type, externs: Set<Str>) -> Bool {
    match ty {
        Type::UnitType => true,
        Type::PtrType { .. } => true,
        _ => is_extern_handle_type(ty, externs),
    }
}

// B-002p1: check whether a type has user `impl Drop` (move semantics, no dup).
pub fn is_user_drop_type(ty: Type, drop_types: Set<Str>) -> Bool {
    match ty {
        Type::StructType { name, .. } => drop_types.contains(name),
        Type::EnumType { name, .. } => drop_types.contains(name),
        _ => false
    }
}

// A type whose values, when DEEP-DROPPED, would reach a foreign handle: the
// extern type itself, or a container / Option / tuple / struct / enum that
// transitively holds one (e.g. `List<LLVMTypeRef>` — drop_list ring_drops each
// element; `LLVMValueRef?` — drop_option drops the payload; `LlvmCtx` — its
// drop_T would drop extern fields and `Map<Str, LLVMValueRef>` fields whose
// runtime drop_map drops the foreign values).  Such values must never be
// scope-end-dropped or materialised (leak instead — crash-free direction).
// A SHALLOW ring_dup on a non-extern container of extern handles is safe (the
// container itself has a real RC header), so Clone-on-escape stays allowed for
// these (only the DIRECT extern type suppresses Clone — is_extern_handle_type).
//
// FnType is NOT recursed: a closure's captures are not described by its
// signature, and drop_closure_env releases captures, not param/return values.
// Recursive types terminate via an on-stack visited set (struct/enum names);
// monotone OR + one full exploration per name keeps reachability exact.
pub fn type_contains_extern_handle(ty: Type, externs: Set<Str>) -> Bool {
    if externs.len() == 0 {
        false
    } else {
        let mut visited: Set<Str> = set_new()
        type_contains_extern_rec(ty, externs, visited)
    }
}

fn type_contains_extern_rec(ty: Type, externs: Set<Str>, mut visited: Set<Str>) -> Bool {
    match ty {
        // B-152: Ptr<T> is RC-excluded (B-125); ring_drop on a raw pointer reads
        // garbage headers.  Skip it in the field-drop loop, same as extern handles.
        Type::PtrType { .. } => true,
        Type::StructType { name, type_params } => {
            if externs.contains(name) {
                true
            } else if visited.contains("S:${name}") {
                false
            } else {
                visited.insert("S:${name}")
                let mut found = false
                for tp in type_params {
                    if type_contains_extern_rec(tp, externs, visited) { found = true }
                }
                found
            }
        },
        Type::EnumType { name, type_params } => {
            if visited.contains("E:${name}") {
                false
            } else {
                visited.insert("E:${name}")
                let mut found = false
                for tp in type_params {
                    if type_contains_extern_rec(tp, externs, visited) { found = true }
                }
                found
            }
        },
        Type::TupleType { elements } => {
            let mut found = false
            for e in elements {
                if type_contains_extern_rec(e, externs, visited) { found = true }
            }
            found
        },
        Type::GenericType { base, args } => {
            let mut found = type_contains_extern_rec(base, externs, visited)
            for a in args {
                if type_contains_extern_rec(a, externs, visited) { found = true }
            }
            found
        },
        Type::RecordType { fields: field_values, .. } => {
            let mut found = false
            for f in field_values {
                if type_contains_extern_rec(f.ty, externs, visited) { found = true }
            }
            found
        },
        _ => false,
    }
}

// ============================================================
// B-104 return-mode predicates (shared perceus ↔ LLVM codegen)
// ============================================================
//
// These were perceus-internal until D1 Stage 2; the codegen-level condition-box
// drops (emit_while / match-guard post-unbox — see is_fresh_owned_bool_value)
// need the same classification, and cross-stage contracts live in hir.ring.
// THE EVIDENCE RECORD (the complete B-103 ring_runtime.cpp return-mode
// classification table, function by function) remains in perceus.ring directly
// above its former location — read it before touching membership here.

// A method call whose result is a BORROW of (an inner reference of) its
// receiver or an argument, returned WITHOUT a dup by the runtime — escaping it
// needs a Clone, and scope-end-dropping its binding would free a reference
// owned elsewhere.  Membership = the 4 Option projections (B-104 D1 rule ②
// retired the 9 receiver-returning mutator names — their protection is the
// type-level Unit exclusion).  Safety asymmetry: omitting a genuine borrow
// returner CRASHES (UAF); mis-listing a fresh returner only leaks.
pub fn is_borrow_returning_call(callee: HExpr) -> Bool {
    match callee {
        HExpr::FieldAccess { field, .. } =>
            field == "unwrap" || field == "to_fail"
            || field == "unwrap_or" || field == "unwrap_or_else",
        _ => false,
    }
}

// is_arg_returning_call (sole member `fold`) was RETIRED here on 2026-06-12
// (B-104 D1 Stage 3, audit #150): ring_list_fold now dups `init` on the
// empty-receiver path, so no runtime callee returns an argument verbatim with
// a moved result — every call result is OWNED on every path.

// B-104 D1 Stage 2 — fresh-owned Bool CONDITION value (the while-cond /
// match-guard box).  HIR cannot express "unbox the condition, THEN release the
// box" — the unbox is emitted inside codegen's condition lowering, so the drop
// must be emitted there too (same pattern as the B-104b range-loop drops in
// emit_for_in_range_direct).  This predicate is the perceus-blessed ownership
// answer: TRUE iff the expression's value is a freshly-allocated Bool box whose
// FINAL consumer is that unbox, so a post-unbox ring_drop is balanced:
//   * BinOp → comparison/eq lowers to box_bool (fresh).  (`&&`/`||` never
//     appear here — B-104 D7: andor_lower rewrites them to IfExpr at checker
//     end; their phi classifies via the If/Match recursion below.)
//   * UnaryOp → `!x` boxes a fresh result.
//   * Call, unless borrow-returning (unwrap family → borrow of the receiver's
//     payload): a Ring fn returns OWNED (clone-all-escape Clone-wraps tail
//     borrows) and scalar builtins are boxed fresh at the call site (`fold`
//     included since the #150 empty-path dup — owned on every path).
//   * BoolLit → a fresh box per evaluation (`while true`).
//   * Clone → an owned dup by construction (a dropping cond-block's
//     Clone-wrapped tail — rc_block_inner's tail-escape invariant).
//   * Block → its value is its tail's value → recurse.
//   * If/Match (B-104 D2) → TRUE iff EVERY branch tail is itself
//     is_fresh_owned_bool_value (the W3a branch-value recursion, bottoming
//     out on the same leaf classification).  Covers the match-valued
//     while-cond (`while match make(i) { some(p) => p.flag, none => false }`):
//     in a DROPPING cond-block the tail-escape invariant Clone-wraps every
//     owner-bearing arm tail, so the phi box is always a fresh dup/box that
//     leaked once per ITERATION pre-D2 (verifier finding on
//     receiver_temp_drop.ring).  A bare borrow arm tail (`m => obj.flag`,
//     un-Cloned in a no-drop cond) classifies false → whole phi false →
//     conservative no-drop, exactly as before.  A DIVERGING arm (Block ending
//     in return — no tail) classifies false → conservative leak-direction.
// Everything else (Ident / FieldAccess / IndexExpr reads, EffectOp, …) →
// false: borrow or unknown ownership — leak-direction.  The
// BoolType requirement is a belt against audit #149 TypeVar-typed conditions
// (an unannotated fn's over-generalised return — unknown ownership, possibly
// the Unit ABI receiver-return accident).
pub fn is_fresh_owned_bool_value(expr: HExpr) -> Bool {
    let is_bool = match hexpr_type(expr) {
        Type::BoolType => true,
        _ => false,
    }
    if is_bool == false {
        return false
    }
    match expr {
        HExpr::BinOp { .. } => true,
        HExpr::UnaryOp { .. } => true,
        HExpr::Call { callee, .. } =>
            is_borrow_returning_call(callee) == false,
        HExpr::BoolLit { .. } => true,
        HExpr::Clone { .. } => true,
        // A Block's value is its tail's value.  POST-RC SHAPE: a block that
        // emits scope-end drops has its tail HOISTED by rc_block_inner into a
        // fresh `let __rc_scope_N = <escape-processed tail>` (so the drops run
        // after the tail is computed) and the syntactic tail becomes an Ident
        // referencing it.  That binding's value is OWNED by construction (the
        // tail-escape invariant moves a fresh tail / Clone-wraps an
        // owner-bearing one) and is never in the block's own drop set (it is
        // created after block_locals).  So: a non-Ident tail classifies
        // directly; an Ident tail classifies via the init of its exact DefId
        // among this block's direct statements (the hoist, or a
        // user binding — which, in a NON-dropping block, was necessarily
        // non-droppable, so its init classifies false: borrows stay
        // un-dropped).  An Ident with no binding in this block is an outer
        // borrow → false.
        HExpr::Block { stmts, tail, .. } => match tail {
            some(t) => match t {
                HExpr::Ident { def_id, .. } => match def_id {
                    some(id) => match block_local_init(stmts, id) {
                        some(init) => is_fresh_owned_bool_value(init),
                        none => false
                    },
                    none => false
                },
                _ => is_fresh_owned_bool_value(t),
            },
            none => false,
        },
        HExpr::IfExpr { then_branch, else_branch, .. } => match else_branch {
            none => false,
            some(eb) => is_fresh_owned_bool_value(then_branch) && is_fresh_owned_bool_value(eb),
        },
        HExpr::MatchExpr { arms, .. } => {
            let mut all = arms.len() > 0
            for arm in arms {
                if is_fresh_owned_bool_value(arm.body) == false { all = false }
            }
            all
        },
        _ => false,
    }
}

// Comparator for sort_by on (Str, _) tuples — compares by first element.
// Used across 55+ call sites to deterministically sort Map.entries() etc.
pub fn compare_by_first<T>(a: (Str, T), b: (Str, T)) -> Int {
    if a.0 < b.0 { -1 } else if a.0 > b.0 { 1 } else { 0 }
}

// The initialiser of the exact direct `let`/`var` statement binding `def_id` in a
// statement list (helper for is_fresh_owned_bool_value's post-RC Block arm).
fn block_local_init(stmts: List<HStmt>, def_id: Int) -> HExpr? {
    let mut found: HExpr? = none
    for s in stmts {
        match s {
            HStmt::Let { def_id: some(id), init, .. } => {
                if id == def_id { found = some(init) }
            },
            HStmt::Var { def_id: some(id), init, .. } => {
                if id == def_id { found = some(init) }
            },
            _ => {},
        }
    }
    found
}
