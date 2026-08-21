use ast::{Span, Pattern, BinOp, UnaryOp, TypeParam}
use types::{Type, EffectRow, StructField, EnumVariant, RecordField}

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
pub const CHECKER_ONLY_EXTERN_CALLABLES: List<Str> =
    ["Cell", "alloc", "dealloc", "ptr_copy", "ptr_from_addr"]

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
    pub is_trait_impl: Bool,
    // fn-method names in declaration order (delegates excluded upstream by
    // HIR construction only when they do not lower to HDecl::Fn).
    pub method_names: List<Str>,
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

fn slot_bridge_identity(source_name: Str) -> Str {
    compiler_intrinsic_identity("prelude$slot", source_name)
}

pub fn slot_read_identity() -> Str {
    slot_bridge_identity(slot_read_source_name())
}

pub fn slot_take_identity() -> Str {
    slot_bridge_identity(slot_take_source_name())
}

pub fn slot_write_identity() -> Str {
    slot_bridge_identity(slot_write_source_name())
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

// B-104 D4 (#151): dict evidence is FIRST-CLASS in HIR.  Three reference forms:
//   Simple(name)  — a SCOPE reference: a dict PARAM (`__ring_T_Eq`, from
//                   trait_bound_param_name) or a dict LOCAL synthesised by the
//                   dict-lowering pass (`__ring_dictlocal_N`).  Borrow — the
//                   referenced binding owns the dict.
//   Static(name)  — a MODULE-LEVEL STATIC dict singleton reference (borrow):
//                   either a plain dict (`__Type_Trait` impl dict / builtin
//                   primitive dict) or a fully-static wrapped INSTANCE
//                   (dict_instance_name).  Singletons live for the program
//                   lifetime — never Clone'd, never Drop'ed, never owned.
//                   Produced by infer (plain) / dict_lower (instances).
//   Wrapped{..}   — the infer-side RESOLUTION form for a parameterized type's
//                   dict (base dict + inner dicts).  dict_lower rewrites every
//                   use site: all-static → Static(instance); any dynamic inner
//                   → a local `let __ring_dictlocal_N = HExpr::DictConstruct`
//                   + Simple(local).  After dict_lower, Wrapped survives in
//                   BinOp eq/ord_dispatch extra_dicts and in dynamic derived
//                   FieldAction evidence, whose synthetic methods construct
//                   and reclaim the wrapper directly.
pub enum DictRef {
    Simple(Str),
    Wrapped { dict: Str, trait_name: Str, inner_dicts: List<DictRef> },
    Static(Str)
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

pub struct DictDispatchInfo {
    // Bound dispatch is Simple; delegated concrete/default dispatch is
    // Static.  The tag is the authority -- codegen never guesses a domain
    // from the spelling.
    pub dict_ref: DictRef,
    pub method: Str
}

pub struct HStructFieldInit {
    pub name: Str,
    pub value: HExpr
}

// Pattern AST preserves source shape.  This parallel transport is the exact
// lexical slot contract consumed by RC verification and native lowering.
pub struct HPatternBinding {
    pub name: Str,
    pub def_id: Int,
    pub ty: Type
}

pub struct HMatchArm {
    pub pattern: Pattern,
    pub bindings: List<HPatternBinding>,
    pub guard: HExpr?,
    pub body: HExpr,
    pub span: Span
}

pub struct HEffectHandler {
    pub effect_name: Str,
    pub op_name: Str,
    pub params: List<HParam>,
    pub resume_binding: HPatternBinding?,
    pub body: HExpr
}

pub enum HStringInterpPart {
    Literal(Str),
    Expression(HExpr)
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
    Ident { name: Str, resolved_name: Str?, def_id: Int?, dict_closure_dicts: List<DictRef>?, ty: Type, effects: EffectRow, span: Span },
    BinOp { op: BinOp, left: HExpr, right: HExpr, eq_dispatch: TraitDispatch?, ord_dispatch: TraitDispatch?, ty: Type, effects: EffectRow, span: Span },
    UnaryOp { op: UnaryOp, operand: HExpr, ty: Type, effects: EffectRow, span: Span },
    Call { callee: HExpr, args: List<HExpr>, type_args: List<Type>, resolved_dicts: List<DictRef>, dict_dispatch: DictDispatchInfo?, ty: Type, effects: EffectRow, span: Span },
    FieldAccess { receiver: HExpr, field: Str, ty: Type, effects: EffectRow, span: Span },
    StructLit { name: Str, type_args: List<Type>, fields: List<HStructFieldInit>, spread: HExpr?, ty: Type, effects: EffectRow, span: Span },
    NamedVariantConstruct { enum_name: Str, variant_name: Str, fields: List<HStructFieldInit>, spread: HExpr?, ty: Type, effects: EffectRow, span: Span },
    MatchExpr { scrutinee: HExpr, arms: List<HMatchArm>, ty: Type, effects: EffectRow, span: Span },
    Block { stmts: List<HStmt>, tail: HExpr?, ty: Type, effects: EffectRow, span: Span },
    IfExpr { condition: HExpr, then_branch: HExpr, else_branch: HExpr?, ty: Type, effects: EffectRow, span: Span },
    StringInterp { parts: List<HStringInterpPart>, ty: Type, effects: EffectRow, span: Span },
    TryCatch { body: HExpr, arms: List<HMatchArm>, ty: Type, effects: EffectRow, span: Span },
    HandleExpr { body: HExpr, handlers: List<HEffectHandler>, ty: Type, effects: EffectRow, span: Span },
    Lambda { params: List<HParam>, return_type: Type, body: HExpr, ty: Type, effects: EffectRow, span: Span },
    EffectOp { effect_name: Str, op_name: Str, args: List<HExpr>, ty: Type, effects: EffectRow, span: Span },
    RangeExpr { start: HExpr, end: HExpr, inclusive: Bool, ty: Type, effects: EffectRow, span: Span },
    ListLit { elements: List<HExpr>, ty: Type, effects: EffectRow, span: Span },
    TupleLit { elements: List<HExpr>, ty: Type, effects: EffectRow, span: Span },
    IndexExpr { receiver: HExpr, index: HExpr, ty: Type, effects: EffectRow, span: Span },
    // B-104 D4 (#151): LOCAL construction of a DYNAMIC wrapped dict (at least
    // one inner is a dict param / dict local — unknowable at module scope).
    // Synthesised by dict_lower as the init of a `let __ring_dictlocal_N = …`
    // immediately above the consuming call; the binding is FRESH-OWNED and is
    // reclaimed by the ordinary Perceus scope-end drop (D1/D2 coverage).
    // `inner` entries are Simple (param/local borrow) or Static (singleton
    // borrow) — never Wrapped (dict_lower flattens nested dynamics into their
    // own locals first).  ty is TupleType{[]} (a dict IS a tuple of method
    // closures); effects are pure.
    DictConstruct { base_dict: Str, trait_name: Str, inner: List<DictRef>, ty: Type, effects: EffectRow, span: Span },
    // B-098: value-level clone inserted by the Perceus L1 borrow-inference pass
    // (clone-all-escape).  Wraps an escaping value that
    // already has an independent owner (Ident binding / FieldAccess / IndexExpr /
    // container read result) so the escape gets its own owned reference rather
    // than aliasing the still-live source.  codegen lowers `Clone{inner}` to
    // eval inner -> ring_dup(result) -> result (ty/effects/span taken from inner).
    Clone { inner: HExpr, ty: Type, effects: EffectRow, span: Span },
    ReturnExpr { value: HExpr?, ty: Type, effects: EffectRow, span: Span },
    UnsafeBlock { body: HExpr, ty: Type, effects: EffectRow, span: Span }
}

pub struct HForInDestructure {
    pub name: Str,
    pub def_id: Int?
}

pub struct HLetDestructureBinding {
    pub name: Str,
    pub def_id: Int?,
    pub ty: Type
}

pub enum HStmt {
    Let { name: Str, name_span: Span, def_id: Int?, ty: Type, init: HExpr, span: Span },
    Var { name: Str, name_span: Span, def_id: Int?, ty: Type, init: HExpr, span: Span },
    Assign { target: HExpr, value: HExpr, span: Span },
    ExprStmt { expr: HExpr, span: Span },
    Return { value: HExpr?, span: Span },
    While { condition: HExpr, body: HExpr, span: Span },
    ForIn { binding: Str, binding_span: Span, def_id: Int?, destructure: List<HForInDestructure>?, iterable: HExpr, body: HExpr, iterable_type_name: Str?, iter_type_name: Str?, span: Span },
    Break { span: Span },
    Continue { span: Span },
    LetDestructure { pattern: Pattern, bindings: List<HLetDestructureBinding>, init: HExpr, span: Span },
    IfLet { pattern: Pattern, bindings: List<HPatternBinding>, expr: HExpr, then_block: HExpr, else_block: HExpr?, span: Span },

    // Perceus RC: explicit reference counting op inserted by the RC pass.
    Drop { name: Str, def_id: Int, ty: Type, span: Span }
}

pub struct HStructField {
    pub name: Str,
    pub ty: Type,
    pub is_pub: Bool
}

pub struct HEnumVariant {
    pub name: Str,
    pub fields: List<Type>,
    pub field_names: List<Str>?
}

pub struct HEffectOp {
    pub name: Str,
    pub params: List<HParam>,
    pub return_type: Type,
    pub has_default: Bool,
    pub default_body: HExpr?
}

pub struct HTraitMethod {
    pub name: Str,
    pub params: List<HParam>,
    pub return_type: Type,
    pub effects: EffectRow,
    pub has_default: Bool,
    pub body: HExpr?
}

pub struct TraitBound {
    pub type_param: Str,
    pub trait_name: Str
}

pub struct HAssocType {
    pub name: Str,
    pub bounds: List<Str>,
    pub concrete: Type?
}

pub struct HSigMember {
    pub name: Str,
    pub fn_type: Type,
    pub span: Span
}

pub enum HDecl {
    Fn { name: Str, def_id: Int?, type_params: List<TypeParam>, params: List<HParam>, return_type: Type, effects: EffectRow, body: HExpr, is_pub: Bool, trait_bounds: List<TraitBound>, span: Span },
    Struct { name: Str, type_params: List<TypeParam>, fields: List<HStructField>, is_pub: Bool, span: Span },
    Enum { name: Str, type_params: List<TypeParam>, variants: List<HEnumVariant>, is_pub: Bool, span: Span },
    Impl { target_type: Str, type_params: List<TypeParam>, trait_name: Str?, methods: List<HDecl>, assoc_types: List<HAssocType>, span: Span },
    Effect { name: Str, type_params: List<TypeParam>, ops: List<HEffectOp>, is_pub: Bool, span: Span },
    Test { description: Str, body: HExpr, span: Span },
    Trait { name: Str, type_params: List<TypeParam>, methods: List<HTraitMethod>, supertraits: List<Str>, assoc_types: List<HAssocType>, is_pub: Bool, span: Span },
    ExternFn { name: Str, abi_name: Str, def_id: Int?, type_params: List<TypeParam>, params: List<HParam>, return_type: Type, effects: EffectRow, is_pub: Bool, span: Span },
    ExternType { name: Str, type_params: List<TypeParam>, is_pub: Bool, span: Span },
    TypeAlias { name: Str, ty: Type, is_pub: Bool, span: Span },
    Const { name: Str, def_id: Int?, ty: Type, init: HExpr, is_pub: Bool, span: Span },
    ModBlock { name: Str, decls: List<HDecl>, is_pub: Bool, span: Span },
    Sig { name: Str, members: List<HSigMember>, is_pub: Bool, span: Span }
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
    Call { base_dict: DictRef, extra_dicts: List<DictRef> },
    Tuple { element_actions: List<FieldAction> },
    FnLiteral
}

pub struct DerivedField {
    pub name: Str,
    pub positional_index: Int?,
    pub action: FieldAction
}

pub struct DerivedVariant {
    pub name: Str,
    // Stable declaration-order discriminator mixed into derived Hash before
    // payload fields.  This is a front-end contract, not a backend type/name
    // hash or allocation-dependent value.
    pub discriminator: Int,
    pub fields: List<DerivedField>,
    pub has_named_fields: Bool
}

pub enum TypeKind { StructKind, EnumKind }

// Shared initial state for C/LLVM structural Hash emission.  Kept within the
// signed 63-bit Ring Int range so boxing/unboxing is identical in both
// backends.
pub const DERIVED_HASH_SEED: Int = 1469598103934665603

pub struct DerivedImpl {
    pub type_name: Str,
    pub trait_name: Str,
    pub type_params: List<Str>,
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
        Pattern::Constructor { fields, .. } => {
            for field in fields { collect_hir_pattern_names(field, names) }
        },
        Pattern::NamedConstructor { fields, .. } => {
            for field in fields {
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
        HStmt::ForIn { binding, def_id, destructure,
                       iterable, body, .. } => {
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
        HStmt::LetDestructure { bindings, init, .. } => {
            validate_hir_expr(init, seen, scope)
            for binding in bindings {
                if binding.name != "_" {
                    let id = required_hir_def_id(binding.def_id,
                        "destructure binding '${binding.name}'")
                    validate_hir_binder(seen, id,
                        "destructure binding '${binding.name}'")
                    bind_hir_validation_scope(scope, binding.name, id)
                }
            }
        },
        HStmt::IfLet { pattern, bindings, expr,
                       then_block, else_block, .. } => {
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
        HStmt::Drop { name, def_id, .. } =>
            validate_hir_drop_reference(scope, name, def_id),
        HStmt::Break { .. } | HStmt::Continue { .. } => {}
    }
}

fn validate_hir_field_values(
    fields: List<HStructFieldInit>, spread: HExpr?,
    mut seen: Set<Int>, mut scope: HirValidationScope
) {
    for field in fields {
        validate_hir_expr(field.value, seen, scope)
    }
    match spread {
        some(value) => validate_hir_expr(value, seen, scope),
        none => {}
    }
}

fn validate_hir_expr_values(
    values: List<HExpr>, mut seen: Set<Int>, mut scope: HirValidationScope
) {
    for value in values {
        validate_hir_expr(value, seen, scope)
    }
}

fn validate_hir_expr(
    expr: HExpr, mut seen: Set<Int>, mut scope: HirValidationScope
) {
    match expr {
        HExpr::Ident { name, def_id, .. } =>
            validate_hir_local_reference(
                scope, name, def_id, "Ident"),
        HExpr::BinOp { left, right, .. } => {
            validate_hir_expr(left, seen, scope)
            validate_hir_expr(right, seen, scope)
        },
        HExpr::UnaryOp { operand, .. } =>
            validate_hir_expr(operand, seen, scope),
        HExpr::Call { callee, args, .. } => {
            validate_hir_expr(callee, seen, scope)
            for arg in args { validate_hir_expr(arg, seen, scope) }
        },
        HExpr::FieldAccess { receiver, .. } =>
            validate_hir_expr(receiver, seen, scope),
        HExpr::StructLit { fields, spread, .. } =>
            validate_hir_field_values(fields, spread, seen, scope),
        HExpr::NamedVariantConstruct { fields, spread, .. } =>
            validate_hir_field_values(fields, spread, seen, scope),
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
        HExpr::StringInterp { parts, .. } => {
            for part in parts {
                match part {
                    HStringInterpPart::Literal(_) => {},
                    HStringInterpPart::Expression(value) =>
                        validate_hir_expr(value, seen, scope)
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            validate_hir_expr(body, seen, scope)
            for arm in arms {
                validate_hir_arm(arm, seen, scope, "catch arm")
            }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            validate_hir_expr(body, seen, scope)
            for handler in handlers {
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
        },
        HExpr::Lambda { params, body, .. } => {
            push_hir_validation_scope(scope)
            validate_hir_params(params, seen, scope, "lambda")
            validate_hir_expr(body, seen, scope)
            pop_hir_validation_scope(scope)
        },
        HExpr::EffectOp { args, .. } => {
            for arg in args { validate_hir_expr(arg, seen, scope) }
        },
        HExpr::RangeExpr { start, end, .. } => {
            validate_hir_expr(start, seen, scope)
            validate_hir_expr(end, seen, scope)
        },
        HExpr::ListLit { elements, .. } =>
            validate_hir_expr_values(elements, seen, scope),
        HExpr::TupleLit { elements, .. } =>
            validate_hir_expr_values(elements, seen, scope),
        HExpr::IndexExpr { receiver, index, .. } => {
            validate_hir_expr(receiver, seen, scope)
            validate_hir_expr(index, seen, scope)
        },
        HExpr::Clone { inner, .. } =>
            validate_hir_expr(inner, seen, scope),
        HExpr::ReturnExpr { value, .. } => match value {
            some(inner) => validate_hir_expr(inner, seen, scope),
            none => {}
        },
        HExpr::UnsafeBlock { body, .. } =>
            validate_hir_expr(body, seen, scope),
        HExpr::IntLit { .. } | HExpr::FloatLit { .. } |
        HExpr::StrLit { .. } | HExpr::BoolLit { .. } |
        HExpr::DictConstruct { .. } => {}
    }
}

fn validate_hir_decls(decls: List<HDecl>, mut seen: Set<Int>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, def_id, params, body, .. } => {
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
            HDecl::Impl { methods, .. } => validate_hir_decls(methods, seen),
            HDecl::Effect { name, ops, .. } => {
                for op in ops {
                    match op.default_body {
                        some(body) => {
                            let mut scope = new_hir_validation_scope()
                            validate_hir_params(op.params, seen, scope,
                                "effect default '${name}.${op.name}'")
                            validate_hir_expr(body, seen, scope)
                        },
                        none => {}
                    }
                }
            },
            HDecl::Test { body, .. } => {
                let mut scope = new_hir_validation_scope()
                validate_hir_expr(body, seen, scope)
            },
            HDecl::Trait { name, methods, .. } => {
                for method in methods {
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
            HDecl::Const { name, def_id, init, .. } => {
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
            HDecl::Struct { .. } | HDecl::Enum { .. } |
            HDecl::ExternFn { .. } | HDecl::ExternType { .. } |
            HDecl::TypeAlias { .. } | HDecl::Sig { .. } => {}
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

pub fn evidence_param_name(effect_name: Str) -> Str {
    let safe = if effect_name.contains("::") { effect_name.replace("::", "$") } else { effect_name }
    "__ring_ev_${safe}"
}

// Reverse evidence_param_name back to the canonical effect identity used by
// checker/codegen registries.  File-module identities have the shape
// `path$segments$$_Decl::inline`; the `$` before the `$$_` boundary belongs to
// the resolver module prefix and must stay encoded.  Only `$` after that
// boundary represents inline `::`.  Without a file-module boundary, every `$`
// represents an inline module separator because `$` is illegal in source
// identifiers.
pub fn effect_name_from_evidence_param(param_name: Str) -> Str {
    let prefix = "__ring_ev_"
    let encoded = param_name.slice(prefix.len(), param_name.len())
    match encoded.index_of("$$_") {
        some(boundary_start) => {
            let suffix_start = boundary_start + "$$_".len()
            let file_identity = encoded.slice(0, suffix_start)
            let inline_suffix = encoded.slice(suffix_start, encoded.len()).replace("$", "::")
            "${file_identity}${inline_suffix}"
        },
        none => encoded.replace("$", "::"),
    }
}

pub fn default_evidence_name(effect_name: Str) -> Str {
    let safe = if effect_name.contains("::") { effect_name.replace("::", "$") } else { effect_name }
    "__ring_default_ev_${safe}"
}

// B-090: declaration-order index of an op within its effect. This is the
// cross-phase contract between gen_handle_expr (which lays out the N-slot
// evidence struct, slot k = op k's {fn_ptr, env} closure) and gen_effect_op
// (which GEPs to this slot to dispatch). Slot order = op order in the effect
// declaration. Property is identical to variant_ctor_name: a naming/layout
// convention shared across codegen phases that must never be hardcoded per-site.
// Returns -1 if the op is not found (well-typed code never hits this — the
// checker rejects ops not declared on the effect).
pub fn effect_op_slot(effect_ops: Map<Str, List<HEffectOp>>, effect_name: Str, op_name: Str) -> Int {
    match effect_ops.get(effect_name) {
        some(ops) => {
            let mut idx = 0
            let mut found = -1
            for o in ops {
                if o.name == op_name && found == -1 { found = idx }
                idx = idx + 1
            }
            found
        },
        none => -1,
    }
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
        Type::RecordType { fields, .. } => {
            let mut found = false
            for f in fields {
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
