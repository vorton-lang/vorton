// C-native emission context and shared helpers.  A module is assembled as
// plain C11 source text with zero FFI during compilation.
//
// Value representation at the runtime C ABI:
//   * every Ring value crosses function boundaries as `void*`
//   * Int/Bool are tagged pointers: (value << 1) | 1  (B-080)
//   * Float/Str/List/... are ring_alloc'd heap objects with an
//     [rc:u32 | typeid:u32] header at ptr-8 (Perceus RC)
//   * ring_runtime.cpp C ABI functions are called directly by name.

use types::{Type}
use ast::{Span}
use hir::{HDictDef, TraitBound}
use ir_identity::{SlotRef, slot_ref_stable_key}
use legacy_projection::{LegacyEffectCtxToken}

// Per-function registration info (forward-declare pass).
// Exact C prototype arity. Ring callables include one trailing EffectCtx*;
// backend-only helpers do not.
pub struct CFnInfo {
    pub c_name: Str,
    pub total_params: Int,
    pub takes_effect_ctx: Bool
}

// Struct field layout registration (field ORDER is the C struct layout:
// field i lives at ((void**)ptr)[i] — every slot is one boxed void*).
// field_rc_skip (B-104 D1 rule ①, audit #139): fields whose Ring type is (or
// transitively contains) an extern handle / Ptr<T> — emit_c_drop_functions
// must not ring_drop them (raw foreign pointers; leak instead of crash).
pub struct CStructInfo {
    pub field_names: List<Str>,
    pub field_rc_skip: List<Bool>
}

// Enum variant registration.  Value layout at the runtime C ABI:
//   { int64_t tag, void* field0, ..., void* field(max_fields-1) }
// tag at *(int64_t*)ptr, payload field i at ((void**)ptr)[i + 1].
// field_rc_skip: same extern-containment flags as CStructInfo, per payload
// field — consumed by emit_c_drop_functions.
pub struct CEnumVariantInfo {
    pub tag: Int,
    pub field_count: Int,
    pub field_names: List<Str>,
    pub field_rc_skip: List<Bool>
}

pub struct CEnumInfo {
    pub variants: Map<Str, CEnumVariantInfo>,
    pub max_fields: Int
}

// One enclosing handle/try scope. A return must pop its catch frame and drop
// each owned child EffectCtx before leaving the C stack frame.
pub struct CHandleCleanup {
    pub needs_catch_pop: Bool,
    pub owned_ctx_vars: List<Str>
}

// H+T final-emission authority. Exact and backend name-only registrations
// have deliberately distinct opaque slot types; callers can only erase them
// through the leaf accessors below.
pub struct CExactSlotRef {
    c_name: Str,
    source_name: Str,
    def_id: Int
}

pub struct CNameOnlySlotRef {
    c_name: Str,
    canonical_key: Str
}

pub enum CRefKind {
    Exact { source_name: Str, def_id: Int },
    NameOnly { canonical_key: Str },
    Static { canonical_key: Str },
    Computed { producer: Str },
    Fresh { producer: Str }
}

pub struct CTypedRef {
    c_name: Str,
    kind: CRefKind,
    load_id: Int
}

pub struct CClosureEdge {
    edge_id: Int,
    parent_frame: Str,
    child_frame: Str
}

pub struct CIdentityEvent {
    event_id: Int,
    kind: Str,
    edge_id: Int,
    load_id: Int,
    parent_frame: Str,
    child_frame: Str,
    domain: Str,
    def_id: Int,
    canonical_key: Str,
    producer: Str,
    source_slot: Str,
    dest_slot: Str,
    index: Int,
    arity: Int
}

pub struct CCtx {
    // ---- module output sections (assembled by generate_c) ----
    pub globals: List<Str>,     // string-constant byte arrays + const globals
    pub fn_protos: List<Str>,   // Ring function prototypes (decl order)
    pub fn_defs: List<Str>,     // completed function definitions (decl order)

    // ---- current function emission state ----
    // All locals/temps are hoisted to the top of the function as cur_decls.
    // This sidesteps every C
    // block-scope pitfall (if/loop bodies assigning result temps, goto over
    // declarations, Ring `let` shadowing).
    pub cur_decls: List<Str>,
    pub cur_body: List<Str>,
    pub used_locals: Set<Str>,
    pub indent: Int,
    pub in_function: Bool,
    pub current_fn_name: Str,

    // ---- counters (module-wide; names stay unique across functions) ----
    pub tmp_counter: Int,
    pub str_counter: Int,
    pub label_counter: Int,
    pub match_counter: Int,

    // ---- registries ----
    pub named_values: Map<Str, Str>,           // ring var name -> C var name
    // Explicit backend-only spelling domain (dict/evidence/thunk binders).
    // A source local is never admitted here merely because named_values has
    // the same spelling.
    pub name_only_slots: Map<Str, CNameOnlySlotRef>,
    // Cleanup-visible HIR identity -> exact C slot and declared spelling.
    pub value_slots_by_def_id: Map<Int, CExactSlotRef>,
    // Semantic/synthetic SlotRef identity is independent from legacy DefId.
    pub value_slots_by_slot_key: Map<Str, CExactSlotRef>,
    pub functions: Map<Str, CFnInfo>,          // C mangled name -> info
    pub fn_mut_params: Map<Str, List<Bool>>,
    pub struct_types: Map<Str, CStructInfo>,
    pub enum_types: Map<Str, CEnumInfo>,
    pub rt_protos: Map<Str, Str>,              // runtime fn name -> full C prototype line
    pub cstr_cache: Map<Str, Str>,             // interned message -> global cstr name
    // C names whose definition has been emitted.  First definition wins:
    // duplicate mangled names (user `enum Result` impl methods colliding with
    // the prelude's `Result` impl) are a single LLVM module symbol there
    // (LLVM auto-uniques; the later body lands in a dead block) — in C a
    // second definition is a hard clang error, so later bodies are skipped.
    pub emitted_fns: Set<Str>,
    // Synthetic derive methods registered before any member of their SCC is
    // emitted. Kept separate from ordinary declarations so a predeclared
    // derive body is not mistaken for a user/manual collision.
    pub predeclared_derived_fns: Set<Str>,
    pub extern_types: Set<Str>,
    // Exact resolved/mangled callable identities, kept separate from
    // `functions`: that map also contains const getters and backend helpers,
    // which are not evidence that an HIR value uses the Ring function ABI.
    pub ring_callable_names: Set<Str>,
    // Exact resolved/mangled HDecl/builtin identities that use the extern
    // direct-call ABI. Function-value lowering compares the same canonical
    // key, so an extern in one module cannot taint an equal leaf elsewhere.
    pub extern_callable_names: Set<Str>,
    // Exact extern registry key -> foreign ABI symbol. `HDecl::ExternFn.name`
    // stays canonical through HIR; only a proven genuine extern call consults
    // this map and crosses back to the ABI leaf.
    pub extern_abi_names: Map<Str, Str>,
    // One project-wide Core/Rc-issued dense token table. C preserves upstream
    // ordinals verbatim and never interns typed instances itself.
    pub effect_ctx_tokens: List<LegacyEffectCtxToken>,
    pub boxed_vars: Set<Int>,
    pub type_to_typeid: Map<Str, Int>,
    pub next_user_typeid: Int,

    // ---- step 7: per-type drop functions (emit_c_drop_functions) ----
    // B-002p1: types with user `impl Drop` — the generated ring_drop_<T> calls
    // the user drop body BEFORE the recursive field drops.
    pub drop_types: Set<Str>,
    // `ring_register_drop(tid, (void*)ring_drop_<T>);` statements, emitted
    // into C main() right after ring_runtime_init (LLVM parity:
    // emit_drop_registrations runs in main's entry block).
    pub drop_registrations: List<Str>,

    // ---- step 5: trait dict / closure registries ----
    // Trait method slot order + supertrait edges — populated from the SHARED
    // hir.ring scan (scan_trait_method_order, plan §2.5 #2: single source, no
    // per-backend registry).
    pub trait_method_order: Map<Str, List<Str>>,
    pub trait_supertraits: Map<Str, List<Str>>,
    // B-104 D4 static dict singleton definitions (HProgram.static_dicts).
    pub static_dict_defs: Map<Str, HDictDef>,
    // Dict names whose ring_dict_build_<name> build fn exists (impl trait
    // dicts pre-registered in the forward pass + derived trait dicts) — the
    // memoised getter routes through the build fn instead of the runtime
    // builtin fallback.  Pre-registration makes getter contents independent
    // of decl order (the LLVM backend's lazy variant is order-sensitive).
    pub dict_build_fns: Set<Str>,
    // Dict names whose memoised getter ring_dict_init_<name> was emitted.
    pub dict_getters: Set<Str>,
    // Function-value dict ABI invariant: the checker must attach exactly one
    // DictRef per bound.  Codegen keeps the declared bounds only to reject a
    // missing/partial dictionary list; it never re-resolves types.
    pub fn_trait_bounds: Map<Str, List<TraitBound>>,
    // Module-wide counters for synthesised functions (deterministic order).
    pub lambda_counter: Int,
    pub dictwrap_counter: Int,

    // Internal-only H+T acceptance ledger. Event order is emission order;
    // these counters never participate in C naming or ordinary output.
    pub identity_ledger_enabled: Bool,
    pub identity_events: List<CIdentityEvent>,
    pub identity_event_counter: Int,
    pub identity_edge_counter: Int,
    pub identity_load_counter: Int,

    // ---- effect handler / catch state ----
    // Enclosing handle/try scopes for `return`-path cleanup (#173).
    pub handle_cleanup_stack: List<CHandleCleanup>,

    // ---- loop context ----
    // The C statement that implements Ring `continue` for the innermost loop:
    // "continue;" for while loops (cond re-evaluated at the top) or
    // "goto <incr label>;" for for-loops (increment/drop sequence first).
    pub loop_continue_stmt: Str,
    pub in_loop: Bool,

    // ---- #line directives (--no-c-lines disables) ----
    pub emit_lines: Bool,
    pub last_line: Int,
    pub last_file: Str,

    // ---- test decls (#215 parity: no fn main -> C main calls tests) ----
    pub test_fns: List<Str>,
    pub test_emit_idx: Int,

    // ---- step 8: project (multi-module) mode ----
    // Current module's mangling prefix during the body pass (mirror of
    // LlvmCtx.module_prefix).  Registry KEYS keep the LLVM backend's
    // ring_<prefix>$$_<name> shape so the resolution chain (imports_map →
    // prefix → bare → precise lookup) ports verbatim; the emitted C symbol
    // is the sanitized CFnInfo.c_name.
    pub module_prefix: Str?,
    // Imported name -> qualified registry key (build_c_imports_map).
    pub imports_map: Map<Str, Str>,
    // Names declared by the CURRENT module (fns/structs/enums/consts/...) —
    // c_resolve_fn qualifies these with module_prefix.
    pub local_names: Set<Str>,
    // Exact mangled extern declaration key -> exact mangled Ring target key.
    // Absence deliberately preserves real FFI.
    pub extern_forward_bridges: Map<Str, Str>
}

pub fn new_c_ctx(emit_lines: Bool) -> CCtx {
    let mut extern_callable_names: Set<Str> = set_new()
    let mut extern_abi_names: Map<Str, Str> = map_new()
    CCtx {
        globals: [],
        fn_protos: [],
        fn_defs: [],
        cur_decls: [],
        cur_body: [],
        used_locals: set_new(),
        indent: 1,
        in_function: false,
        current_fn_name: "",
        tmp_counter: 0,
        str_counter: 0,
        label_counter: 0,
        match_counter: 0,
        named_values: map_new(),
        name_only_slots: map_new(),
        value_slots_by_def_id: map_new(),
        value_slots_by_slot_key: map_new(),
        functions: map_new(),
        fn_mut_params: map_new(),
        struct_types: map_new(),
        enum_types: map_new(),
        rt_protos: map_new(),
        cstr_cache: map_new(),
        emitted_fns: set_new(),
        predeclared_derived_fns: set_new(),
        extern_types: set_new(),
        ring_callable_names: set_new(),
        extern_callable_names: extern_callable_names,
        extern_abi_names: extern_abi_names,
        effect_ctx_tokens: [],
        boxed_vars: set_new(),
        type_to_typeid: map_new(),
        next_user_typeid: 64,
        drop_types: set_new(),
        drop_registrations: [],
        trait_method_order: map_new(),
        trait_supertraits: map_new(),
        static_dict_defs: map_new(),
        dict_build_fns: set_new(),
        dict_getters: set_new(),
        fn_trait_bounds: map_new(),
        lambda_counter: 0,
        dictwrap_counter: 0,
        identity_ledger_enabled: false,
        identity_events: [],
        identity_event_counter: 0,
        identity_edge_counter: 0,
        identity_load_counter: 0,
        handle_cleanup_stack: [],
        loop_continue_stmt: "",
        in_loop: false,
        emit_lines: emit_lines,
        last_line: -1,
        last_file: "",
        test_fns: [],
        test_emit_idx: 0,
        module_prefix: none,
        imports_map: map_new(),
        local_names: set_new(),
        extern_forward_bridges: map_new()
    }
}

// ============================================================
// Name mangling — same scheme as the LLVM backend (ring_<name> /
// ring_<Type>_<method>), sanitized to the portable C identifier set.
// ============================================================

pub fn c_sanitize(name: Str) -> Str {
    let mut parts: List<Str> = []
    for i in 0..name.len() {
        let c = name.char_code_at(i).unwrap_or(95)
        let ok = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95
        if ok {
            parts.push(name[i])
        } else {
            // `$` (module mangling / dict instances) and anything else exotic.
            parts.push("_")
        }
    }
    parts.join("")
}

// Encode a module-qualified registry key as a portable C identifier.
//
// Registry keys deliberately keep the LLVM resolver contract
// (`ring_<module-prefix>$$_<name>`).  Applying c_sanitize to those keys is
// not injective: both `$` and `_` collapse to `_`, so e.g. modules `a::b`
// and `a_b` can emit the same linker symbol.  Project symbols use a separate,
// reversible escape alphabet over the complete input identity:
//   `_` -> `__`, `$` -> `_m`, other non-alnum -> `_x<codepoint>_`.
// Literal underscores are always escaped, so every escape is unambiguous.
// Do not strip a leading `ring_`: it is also a legal module-prefix spelling,
// so stripping would alias `ring_a$$_Foo` with `a$$_Foo` when this encoder is
// used directly on canonical type identities (drop glue, thunks, dictionaries).
// The `ringmod_` namespace cannot collide with ordinary Ring functions,
// whose C symbols always start with `ring_`.
pub fn c_module_symbol(registry_key: Str) -> Str {
    let mut parts: List<Str> = ["ringmod_"]
    for i in 0..registry_key.len() {
        let c = registry_key.char_code_at(i).unwrap_or(95)
        let alnum = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57)
        if alnum {
            parts.push(registry_key[i])
        } else if c == 95 {
            parts.push("__")
        } else if c == 36 {
            parts.push("_m")
        } else {
            parts.push("_x${c}_")
        }
    }
    parts.join("")
}

// Only module-qualified registry keys use the reversible project encoding.
// Single-file symbols and every runtime ABI name retain their byte-for-byte
// step 1-7 spelling.
pub fn c_symbol_for_fn_key(registry_key: Str) -> Str {
    if registry_key.starts_with("ringmod_") {
        registry_key
    } else if registry_key.index_of("$$_").is_some() {
        c_module_symbol(registry_key)
    } else {
        c_sanitize(registry_key)
    }
}

// Encode any identity-bearing fragment that participates in an emitted C
// symbol (drop glue, dictionaries, evidence, thunks, etc.).  Non-module names
// retain the exact step 1-7 ABI spelling; canonical project identities use the
// same injective encoder as function symbols.
pub fn c_symbol_fragment(name: Str) -> Str {
    if name.index_of("$$_").is_some() { c_module_symbol(name) } else { c_sanitize(name) }
}

pub fn c_effect_ctx_token_symbol(ordinal: Int) -> Str {
    if ordinal < 0 {
        panic("C codegen: negative upstream EffectCtx token ordinal")
    }
    "__ring_effect_ctx_token_${ordinal}"
}

pub fn c_mangle_fn(name: Str) -> Str {
    if name.index_of("$$_").is_some() {
        "ring_${name}"
    } else {
        "ring_${c_sanitize(name)}"
    }
}

pub fn c_mangle_method(type_name: Str, method_name: Str) -> Str {
    if type_name.index_of("$$_").is_some() {
        c_module_symbol("ring_${type_name}_${method_name}")
    } else {
        "ring_${c_sanitize(type_name)}_${c_sanitize(method_name)}"
    }
}

// Module-qualified registry KEY: ring_<prefix>$$_<name> — byte-identical to
// llvm_mangle_fn_with_prefix so the module resolution logic ports verbatim.
// NOT a valid C identifier; the emitted symbol is c_sanitize'd in
// c_declare_fn (CFnInfo.c_name), which every call site resolves through.
pub fn c_mangle_fn_with_prefix(prefix: Str, name: Str) -> Str {
    if name.index_of("$$_").is_some() { c_mangle_fn(name) } else { "ring_${prefix}$$_${name}" }
}

// Resolve a function name through module context (port of llvm_resolve_fn):
// imports_map first (cross-module references), then prefix-qualify names the
// current module declares, else bare mangling.
pub fn c_resolve_fn(ctx: CCtx, name: Str) -> Str {
    let direct_key = c_mangle_fn(name)
    if name.index_of("$$_").is_some() {
        // Imported/qualified HIR already carries the declaration module's
        // canonical identity.  It still needs the exact extern-forward plan;
        // otherwise only unqualified calls made inside that module bridge.
        match ctx.extern_forward_bridges.get(direct_key) {
            some(target) => { return target },
            none => { return direct_key },
        }
    }
    match ctx.imports_map.get(name) {
        some(qualified) => match ctx.extern_forward_bridges.get(qualified) {
            some(target) => target,
            none => qualified,
        },
        none => {
            match ctx.module_prefix {
                some(prefix) => {
                    let bridge_key = c_mangle_fn_with_prefix(prefix, name)
                    match ctx.extern_forward_bridges.get(bridge_key) {
                        some(target) => target,
                        none => {
                            if ctx.local_names.contains(name) {
                                bridge_key
                            } else {
                                direct_key
                            }
                        },
                    }
                },
                none => direct_key,
            }
        },
    }
}

// ============================================================
// Emission primitives
// ============================================================

fn indent_of(n: Int) -> Str {
    "    ".repeat(n)
}

// Emit one indented statement line into the current function body.
pub fn c_emit(mut ctx: CCtx, line: Str) {
    ctx.cur_body.push("${indent_of(ctx.indent)}${line}")
}

// Emit a raw (column-0) line: labels, #line directives.
pub fn c_raw(mut ctx: CCtx, line: Str) {
    ctx.cur_body.push(line)
}

// Fresh void* temporary — hoisted declaration + returns the name.
pub fn fresh_tmp(mut ctx: CCtx) -> Str {
    let n = ctx.tmp_counter
    ctx.tmp_counter = n + 1
    let name = "t${n}"
    ctx.cur_decls.push("    void* ${name};")
    name
}

pub fn fresh_effect_ctx_token_array(mut ctx: CCtx, count: Int) -> Str {
    if count <= 0 {
        panic("C codegen: EffectCtx token array must be non-empty")
    }
    let n = ctx.tmp_counter
    ctx.tmp_counter = n + 1
    let name = "effect_tokens_${n}"
    ctx.cur_decls.push("    const void* ${name}[${count}];")
    name
}

pub fn fresh_effect_ctx_evidence_array(mut ctx: CCtx, count: Int) -> Str {
    if count <= 0 {
        panic("C codegen: EffectCtx evidence array must be non-empty")
    }
    let n = ctx.tmp_counter
    ctx.tmp_counter = n + 1
    let name = "effect_evidence_${n}"
    ctx.cur_decls.push("    void* ${name}[${count}];")
    name
}

// Fresh int64_t temporary (loop counters, unboxed condition flags).
pub fn fresh_i64(mut ctx: CCtx) -> Str {
    let n = ctx.tmp_counter
    ctx.tmp_counter = n + 1
    let name = "i${n}"
    ctx.cur_decls.push("    int64_t ${name};")
    name
}

// Fresh double temporary (unboxed float operands).
pub fn fresh_dbl(mut ctx: CCtx) -> Str {
    let n = ctx.tmp_counter
    ctx.tmp_counter = n + 1
    let name = "d${n}"
    ctx.cur_decls.push("    double ${name};")
    name
}

pub fn fresh_label(mut ctx: CCtx, prefix: Str) -> Str {
    let n = ctx.label_counter
    ctx.label_counter = n + 1
    "__ring_${prefix}_${n}"
}

pub fn c_exact_slot_c_name(slot: CExactSlotRef) -> Str { slot.c_name }
pub fn c_exact_slot_def_id(slot: CExactSlotRef) -> Int { slot.def_id }
pub fn c_exact_slot_source_name(slot: CExactSlotRef) -> Str { slot.source_name }
pub fn c_name_only_slot_c_name(slot: CNameOnlySlotRef) -> Str { slot.c_name }
pub fn c_name_only_slot_key(slot: CNameOnlySlotRef) -> Str { slot.canonical_key }

// Register a Ring local binding. Hoisted locals start null so unconditional
// cleanup is safe on control-flow paths that never initialize the slot.
pub fn c_local_def_ref(
    mut ctx: CCtx, ring_name: Str, def_id: Int?
) -> CExactSlotRef {
    if ring_name == "" {
        panic("C codegen: exact local has an empty source name")
    }
    let exact_def_id = match def_id {
        some(id) => id,
        none => panic(
            "C codegen: exact local '${ring_name}' has no DefId")
    }
    if exact_def_id == -1 {
        panic("C codegen: exact local '${ring_name}' has sentinel DefId")
    }
    if ctx.value_slots_by_def_id.contains_key(exact_def_id) {
        panic("C codegen: duplicate local DefId ${exact_def_id}")
    }
    let cname = c_unique_local(ctx, ring_name)
    ctx.cur_decls.push("    void* ${cname} = NULL;")
    ctx.named_values.insert(ring_name, cname)
    let slot = CExactSlotRef {
        c_name: cname, source_name: ring_name, def_id: exact_def_id
    }
    ctx.value_slots_by_def_id.insert(exact_def_id, slot)
    slot
}

pub fn c_local_def(
    mut ctx: CCtx, ring_name: Str, def_id: Int?
) -> Str {
    c_exact_slot_c_name(c_local_def_ref(ctx, ring_name, def_id))
}

pub fn c_local_ref(mut ctx: CCtx, ring_name: Str) -> CNameOnlySlotRef {
    if ring_name == "" {
        panic("C codegen: name-only local has an empty canonical key")
    }
    let cname = c_unique_local(ctx, ring_name)
    ctx.cur_decls.push("    void* ${cname} = NULL;")
    ctx.named_values.insert(ring_name, cname)
    let slot = CNameOnlySlotRef {
        c_name: cname, canonical_key: ring_name
    }
    ctx.name_only_slots.insert(ring_name, slot)
    slot
}

pub fn c_local(mut ctx: CCtx, ring_name: Str) -> Str {
    c_name_only_slot_c_name(c_local_ref(ctx, ring_name))
}

// Register a Ring parameter: unique C name + name map (declared in the
// function signature, so no hoisted decl).
pub fn c_param_def_ref(
    mut ctx: CCtx, ring_name: Str, def_id: Int?
) -> CExactSlotRef {
    if ring_name == "" {
        panic("C codegen: exact parameter has an empty source name")
    }
    let exact_def_id = match def_id {
        some(id) => id,
        none => panic(
            "C codegen: exact parameter '${ring_name}' has no DefId")
    }
    if exact_def_id == -1 {
        panic("C codegen: exact parameter '${ring_name}' has sentinel DefId")
    }
    if ctx.value_slots_by_def_id.contains_key(exact_def_id) {
        panic("C codegen: duplicate parameter DefId ${exact_def_id}")
    }
    let cname = c_unique_local(ctx, ring_name)
    ctx.named_values.insert(ring_name, cname)
    let slot = CExactSlotRef {
        c_name: cname, source_name: ring_name, def_id: exact_def_id
    }
    ctx.value_slots_by_def_id.insert(exact_def_id, slot)
    slot
}

pub fn c_param_def(
    mut ctx: CCtx, ring_name: Str, def_id: Int?
) -> Str {
    c_exact_slot_c_name(c_param_def_ref(ctx, ring_name, def_id))
}

pub fn c_param_ref(mut ctx: CCtx, ring_name: Str) -> CNameOnlySlotRef {
    if ring_name == "" {
        panic("C codegen: name-only parameter has an empty canonical key")
    }
    let cname = c_unique_local(ctx, ring_name)
    ctx.named_values.insert(ring_name, cname)
    let slot = CNameOnlySlotRef {
        c_name: cname, canonical_key: ring_name
    }
    ctx.name_only_slots.insert(ring_name, slot)
    slot
}

pub fn c_param(mut ctx: CCtx, ring_name: Str) -> Str {
    c_name_only_slot_c_name(c_param_ref(ctx, ring_name))
}

pub fn c_value_slot(ctx: CCtx, def_id: Int) -> CExactSlotRef? {
    ctx.value_slots_by_def_id.get(def_id)
}

pub fn c_exact_value_slot(
    ctx: CCtx, name: Str, def_id: Int
) -> CExactSlotRef? {
    match ctx.value_slots_by_def_id.get(def_id) {
        some(slot) => {
            if slot.source_name != name {
                panic("C codegen: DefId ${def_id} names '${slot.source_name}', not '${name}'")
            }
            some(slot)
        },
        none => none
    }
}

fn c_register_semantic_slot(
    mut ctx: CCtx, slot: SlotRef, suggested_name: Str, parameter: Bool,
    c_type: Str
) -> CExactSlotRef {
    let key = slot_ref_stable_key(slot)
    if ctx.value_slots_by_slot_key.contains_key(key) {
        panic("C codegen: duplicate semantic SlotRef")
    }
    let cname = c_unique_local(ctx, suggested_name)
    if !parameter {
        ctx.cur_decls.push("    ${c_type} ${cname} = NULL;")
    }
    let result = CExactSlotRef {
        c_name: cname, source_name: key, def_id: -2
    }
    ctx.value_slots_by_slot_key.insert(key, result)
    result
}

pub fn c_local_semantic_slot(
    mut ctx: CCtx, slot: SlotRef, suggested_name: Str
) -> CExactSlotRef {
    c_register_semantic_slot(ctx, slot, suggested_name, false, "void*")
}

pub fn c_param_semantic_slot(
    mut ctx: CCtx, slot: SlotRef, suggested_name: Str
) -> CExactSlotRef {
    c_register_semantic_slot(ctx, slot, suggested_name, true, "void*")
}

pub fn c_local_effect_ctx_slot(
    mut ctx: CCtx, slot: SlotRef, suggested_name: Str
) -> CExactSlotRef {
    c_register_semantic_slot(
        ctx, slot, suggested_name, false, "EffectCtx*")
}

pub fn c_param_effect_ctx_slot(
    mut ctx: CCtx, slot: SlotRef, suggested_name: Str
) -> CExactSlotRef {
    c_register_semantic_slot(
        ctx, slot, suggested_name, true, "EffectCtx*")
}

pub fn c_semantic_value_slot(
    ctx: CCtx, slot: SlotRef
) -> CExactSlotRef? {
    ctx.value_slots_by_slot_key.get(slot_ref_stable_key(slot))
}

pub fn c_semantic_value_slot_key(
    ctx: CCtx, key: Str
) -> CExactSlotRef? {
    ctx.value_slots_by_slot_key.get(key)
}

pub fn c_register_name_only_ref(
    mut ctx: CCtx, name: Str, c_name: Str
) -> CNameOnlySlotRef {
    if name == "" || c_name == "" {
        panic("C codegen: name-only registration has an empty key/slot")
    }
    let slot = CNameOnlySlotRef {
        c_name: c_name, canonical_key: name
    }
    ctx.name_only_slots.insert(name, slot)
    slot
}

pub fn c_register_name_only_value(
    mut ctx: CCtx, name: Str, c_name: Str
) {
    let _slot = c_register_name_only_ref(ctx, name, c_name)
}

pub fn c_restore_name_only_value(
    mut ctx: CCtx, name: Str, slot: CNameOnlySlotRef
) {
    if slot.canonical_key != name {
        panic("C codegen: restored name-only key '${slot.canonical_key}' as '${name}'")
    }
    ctx.name_only_slots.insert(name, slot)
}

pub fn c_remove_name_only_value(mut ctx: CCtx, name: Str) {
    ctx.name_only_slots.remove(name)
}

pub fn c_name_only_value(ctx: CCtx, name: Str) -> CNameOnlySlotRef? {
    ctx.name_only_slots.get(name)
}

fn validate_identity_domain_shape(
    domain: Str, def_id: Int, canonical_key: Str, producer: Str
) {
    if domain == "exact" {
        if def_id == -1 || canonical_key == "" || producer != "" {
            panic("C identity: malformed Exact domain shape")
        }
    } else {
        if domain == "name-only" || domain == "static" {
            if def_id != -1 || canonical_key == "" || producer != "" {
                panic("C identity: malformed keyed domain shape '${domain}'")
            }
        } else {
            if domain == "computed" || domain == "fresh" {
                if def_id != -1 || canonical_key != "" || producer == "" {
                    panic("C identity: malformed produced domain shape '${domain}'")
                }
            } else {
                panic("C identity: unknown domain '${domain}'")
            }
        }
    }
}

fn validate_c_typed_ref(reference: CTypedRef) -> CTypedRef {
    if reference.c_name == "" || reference.load_id < 0 {
        panic("C identity: typed reference has an empty slot/invalid load id")
    }
    match reference.kind {
        CRefKind::Exact { source_name, def_id } =>
            validate_identity_domain_shape("exact", def_id, source_name, ""),
        CRefKind::NameOnly { canonical_key } =>
            validate_identity_domain_shape("name-only", -1, canonical_key, ""),
        CRefKind::Static { canonical_key } =>
            validate_identity_domain_shape("static", -1, canonical_key, ""),
        CRefKind::Computed { producer } =>
            validate_identity_domain_shape("computed", -1, "", producer),
        CRefKind::Fresh { producer } =>
            validate_identity_domain_shape("fresh", -1, "", producer)
    }
    reference
}

pub fn c_ref_exact(slot: CExactSlotRef) -> CTypedRef {
    validate_c_typed_ref(CTypedRef {
        c_name: slot.c_name,
        kind: CRefKind::Exact {
            source_name: slot.source_name, def_id: slot.def_id
        },
        load_id: 0
    })
}

pub fn c_ref_name_only(slot: CNameOnlySlotRef) -> CTypedRef {
    validate_c_typed_ref(CTypedRef {
        c_name: slot.c_name,
        kind: CRefKind::NameOnly { canonical_key: slot.canonical_key },
        load_id: 0
    })
}

pub fn c_ref_static(c_name: Str, canonical_key: Str) -> CTypedRef {
    validate_c_typed_ref(CTypedRef {
        c_name: c_name,
        kind: CRefKind::Static { canonical_key: canonical_key },
        load_id: 0
    })
}

pub fn c_ref_computed(c_name: Str, producer: Str) -> CTypedRef {
    validate_c_typed_ref(CTypedRef {
        c_name: c_name,
        kind: CRefKind::Computed { producer: producer },
        load_id: 0
    })
}

pub fn c_ref_fresh(c_name: Str, producer: Str) -> CTypedRef {
    validate_c_typed_ref(CTypedRef {
        c_name: c_name,
        kind: CRefKind::Fresh { producer: producer },
        load_id: 0
    })
}

pub fn c_ref_loaded(c_name: Str, producer: Str, load_id: Int) -> CTypedRef {
    if load_id <= 0 { panic("C codegen: loaded reference has invalid load id") }
    validate_c_typed_ref(CTypedRef {
        c_name: c_name,
        kind: CRefKind::Computed { producer: producer },
        load_id: load_id
    })
}

pub fn c_ref_c_name(reference: CTypedRef) -> Str { reference.c_name }
pub fn c_ref_load_id(reference: CTypedRef) -> Int { reference.load_id }

pub fn c_ref_domain(reference: CTypedRef) -> Str {
    match reference.kind {
        CRefKind::Exact { .. } => "exact",
        CRefKind::NameOnly { .. } => "name-only",
        CRefKind::Static { .. } => "static",
        CRefKind::Computed { .. } => "computed",
        CRefKind::Fresh { .. } => "fresh"
    }
}

pub fn c_ref_def_id(reference: CTypedRef) -> Int {
    match reference.kind {
        CRefKind::Exact { def_id, .. } => def_id,
        _ => -1
    }
}

pub fn c_ref_key(reference: CTypedRef) -> Str {
    match reference.kind {
        CRefKind::Exact { source_name, .. } => source_name,
        CRefKind::NameOnly { canonical_key } => canonical_key,
        CRefKind::Static { canonical_key } => canonical_key,
        _ => ""
    }
}

pub fn c_ref_producer(reference: CTypedRef) -> Str {
    match reference.kind {
        CRefKind::Computed { producer } => producer,
        CRefKind::Fresh { producer } => producer,
        _ => ""
    }
}

pub fn c_new_closure_edge(mut ctx: CCtx, child_frame: Str) -> CClosureEdge {
    let edge_id = ctx.identity_edge_counter + 1
    ctx.identity_edge_counter = edge_id
    if ctx.current_fn_name == "" || child_frame == "" {
        panic("C codegen: closure edge has an empty frame")
    }
    CClosureEdge {
        edge_id: edge_id,
        parent_frame: ctx.current_fn_name,
        child_frame: child_frame
    }
}

pub fn c_edge_id(edge: CClosureEdge) -> Int { edge.edge_id }
pub fn c_edge_parent(edge: CClosureEdge) -> Str { edge.parent_frame }
pub fn c_edge_child(edge: CClosureEdge) -> Str { edge.child_frame }

pub fn c_fresh_load_id(mut ctx: CCtx) -> Int {
    let load_id = ctx.identity_load_counter + 1
    ctx.identity_load_counter = load_id
    load_id
}

pub fn c_enable_identity_ledger(mut ctx: CCtx) {
    if ctx.identity_events.len() != 0 {
        panic("C codegen: identity ledger enabled after emission began")
    }
    ctx.identity_ledger_enabled = true
}

fn c_push_identity_event(
    mut ctx: CCtx, kind: Str, edge_id: Int, load_id: Int,
    parent_frame: Str, child_frame: Str, reference: CTypedRef,
    source_slot: Str, dest_slot: Str, index: Int, arity: Int
) {
    if ctx.identity_ledger_enabled == false { return }
    let event_id = ctx.identity_event_counter + 1
    ctx.identity_event_counter = event_id
    ctx.identity_events.push(CIdentityEvent {
        event_id: event_id,
        kind: kind,
        edge_id: edge_id,
        load_id: load_id,
        parent_frame: parent_frame,
        child_frame: child_frame,
        domain: c_ref_domain(reference),
        def_id: c_ref_def_id(reference),
        canonical_key: c_ref_key(reference),
        producer: c_ref_producer(reference),
        source_slot: source_slot,
        dest_slot: dest_slot,
        index: index,
        arity: arity
    })
}

pub fn c_record_capture_extract(
    mut ctx: CCtx, edge: CClosureEdge, reference: CTypedRef,
    source_slot: Str, dest_slot: Str, index: Int
) {
    c_push_identity_event(
        ctx, "capture-extract", edge.edge_id, 0,
        edge.parent_frame, edge.child_frame, reference,
        source_slot, dest_slot, index, 0)
}

pub fn c_record_capture_store(
    mut ctx: CCtx, edge: CClosureEdge, reference: CTypedRef,
    source_slot: Str, dest_slot: Str, index: Int
) {
    c_push_identity_event(
        ctx, "capture-store", edge.edge_id, 0,
        edge.parent_frame, edge.child_frame, reference,
        source_slot, dest_slot, index, 0)
}

pub fn c_record_closure_edge(
    mut ctx: CCtx, edge: CClosureEdge, reference: CTypedRef,
    source_slot: Str, dest_slot: Str
) {
    c_push_identity_event(
        ctx, "closure-edge", edge.edge_id, 0,
        edge.parent_frame, edge.child_frame, reference,
        source_slot, dest_slot, 0, 0)
}

pub fn c_record_receiver_load(
    mut ctx: CCtx, role: Str, load_id: Int, reference: CTypedRef,
    source_slot: Str, dest_slot: Str, index: Int
) {
    let kind = if role == "dict" {
        "dict-receiver-load"
    } else {
        if role == "effect" {
            "effect-receiver-load"
        } else {
            panic("C codegen: unknown receiver-load role '${role}'")
        }
    }
    c_push_identity_event(
        ctx, kind, 0, load_id,
        ctx.current_fn_name, "", reference,
        source_slot, dest_slot, index, 0)
}

pub fn c_record_closure_call(
    mut ctx: CCtx, reference: CTypedRef,
    source_slot: Str, dest_slot: Str, arity: Int
) {
    c_push_identity_event(
        ctx, "closure-call", 0, reference.load_id,
        ctx.current_fn_name, "", reference,
        source_slot, dest_slot, 0, arity)
}

fn identity_event_pair_key(event: CIdentityEvent) -> Str {
    "${event.edge_id}:${event.index}"
}

fn identity_owned_slot_key(frame: Str, slot: Str) -> Str {
    // Collision-free encoding of the (owning frame, raw C slot) pair.
    "${frame.len()}:${frame}:${slot}"
}

fn identity_event_same_identity(a: CIdentityEvent, b: CIdentityEvent) -> Bool {
    a.domain == b.domain &&
    a.def_id == b.def_id &&
    a.canonical_key == b.canonical_key &&
    a.producer == b.producer
}

fn validate_identity_event_shape(event: CIdentityEvent) {
    validate_identity_domain_shape(
        event.domain, event.def_id, event.canonical_key, event.producer)
    if event.kind == "closure-edge" {
        if event.domain != "fresh" ||
           event.producer != "closure-edge:${event.child_frame}" {
            panic("C identity ledger: closure edge has invalid Fresh provenance")
        }
        return
    }
    if event.kind == "capture-store" || event.kind == "capture-extract" {
        if event.domain != "exact" && event.domain != "name-only" {
            panic("C identity ledger: capture has non-slot domain '${event.domain}'")
        }
        return
    }
    if event.kind == "dict-receiver-load" {
        if event.domain != "name-only" && event.domain != "static" &&
           event.domain != "computed" {
            panic("C identity ledger: dict receiver has forbidden '${event.domain}' domain")
        }
        return
    }
    if event.kind == "effect-receiver-load" {
        if event.domain != "name-only" &&
           event.domain != "computed" {
            panic("C identity ledger: effect receiver has forbidden '${event.domain}' domain")
        }
        return
    }
    if event.kind == "closure-call" {
        if event.domain != "exact" && event.domain != "name-only" &&
           event.domain != "computed" {
            panic("C identity ledger: closure call has forbidden '${event.domain}' domain")
        }
        if event.domain == "exact" || event.domain == "name-only" {
            if event.load_id != 0 {
                panic("C identity ledger: slot closure call carries a load id")
            }
        } else {
            let receiver_load = event.producer == "dict-receiver-load" ||
                event.producer == "effect-receiver-load"
            if event.load_id > 0 {
                if receiver_load == false {
                    panic("C identity ledger: loaded closure call has invalid producer")
                }
            } else {
                if event.load_id < 0 || receiver_load {
                    panic("C identity ledger: computed closure call has invalid load shape")
                }
            }
        }
        return
    }
    panic("C identity ledger: unknown event kind '${event.kind}'")
}

fn validate_identity_ledger(ctx: CCtx) {
    let mut edges: Map<Int, CIdentityEvent> = map_new()
    let mut stores: Map<Str, CIdentityEvent> = map_new()
    let mut extracts: Map<Str, CIdentityEvent> = map_new()
    let mut store_indices: Map<Int, Set<Int>> = map_new()
    let mut extract_indices: Map<Int, Set<Int>> = map_new()
    let mut loads: Map<Int, CIdentityEvent> = map_new()
    let mut load_call_counts: Map<Int, Int> = map_new()
    let mut exact_slots: Set<Str> = set_new()
    let mut name_only_slots: Set<Str> = set_new()
    let mut expected_event_id = 1

    for event in ctx.identity_events {
        if event.event_id != expected_event_id {
            panic("C identity ledger: event order drift at ${event.event_id}, expected ${expected_event_id}")
        }
        expected_event_id = expected_event_id + 1
        validate_identity_event_shape(event)

        if event.kind == "closure-edge" {
            if event.edge_id <= 0 || event.parent_frame == "" || event.child_frame == "" ||
               event.source_slot == "" || event.dest_slot == "" {
                panic("C identity ledger: malformed closure edge")
            }
            if edges.contains_key(event.edge_id) {
                panic("C identity ledger: duplicate closure edge ${event.edge_id}")
            }
            edges.insert(event.edge_id, event)
        } else {
            if event.kind == "capture-store" || event.kind == "capture-extract" {
                if event.edge_id <= 0 || event.index <= 0 ||
                   event.source_slot == "" || event.dest_slot == "" {
                    panic("C identity ledger: capture has invalid edge/index")
                }
                let pair_key = identity_event_pair_key(event)
                if event.kind == "capture-store" {
                    if stores.contains_key(pair_key) {
                        panic("C identity ledger: duplicate capture store ${pair_key}")
                    }
                    stores.insert(pair_key, event)
                    match store_indices.get(event.edge_id) {
                        some(indices) => indices.insert(event.index),
                        none => {
                            let mut indices: Set<Int> = set_new()
                            indices.insert(event.index)
                            store_indices.insert(event.edge_id, indices)
                        }
                    }
                    let owned_source = identity_owned_slot_key(
                        event.parent_frame, event.source_slot)
                    if event.domain == "exact" { exact_slots.insert(owned_source) }
                    else { name_only_slots.insert(owned_source) }
                } else {
                    if extracts.contains_key(pair_key) {
                        panic("C identity ledger: duplicate capture extract ${pair_key}")
                    }
                    extracts.insert(pair_key, event)
                    match extract_indices.get(event.edge_id) {
                        some(indices) => indices.insert(event.index),
                        none => {
                            let mut indices: Set<Int> = set_new()
                            indices.insert(event.index)
                            extract_indices.insert(event.edge_id, indices)
                        }
                    }
                    let owned_dest = identity_owned_slot_key(
                        event.child_frame, event.dest_slot)
                    if event.domain == "exact" { exact_slots.insert(owned_dest) }
                    else { name_only_slots.insert(owned_dest) }
                }
            } else {
                if event.kind == "dict-receiver-load" || event.kind == "effect-receiver-load" {
                    if event.load_id <= 0 || event.index <= 0 ||
                       event.parent_frame == "" || event.source_slot == "" ||
                       event.dest_slot == "" {
                        panic("C identity ledger: receiver load has invalid id/index")
                    }
                    if loads.contains_key(event.load_id) {
                        panic("C identity ledger: duplicate receiver load ${event.load_id}")
                    }
                    loads.insert(event.load_id, event)
                    let owned_source = identity_owned_slot_key(
                        event.parent_frame, event.source_slot)
                    if event.domain == "exact" { exact_slots.insert(owned_source) }
                    if event.domain == "name-only" { name_only_slots.insert(owned_source) }
                } else {
                    if event.kind == "closure-call" {
                        if event.arity <= 0 || event.parent_frame == "" ||
                           event.source_slot == "" || event.dest_slot == "" {
                            panic("C identity ledger: closure call has non-positive arity")
                        }
                        if event.load_id > 0 {
                            let prior = match load_call_counts.get(event.load_id) {
                                some(count) => count,
                                none => 0
                            }
                            load_call_counts.insert(event.load_id, prior + 1)
                        }
                        let owned_source = identity_owned_slot_key(
                            event.parent_frame, event.source_slot)
                        if event.domain == "exact" { exact_slots.insert(owned_source) }
                        if event.domain == "name-only" { name_only_slots.insert(owned_source) }
                    } else {
                        panic("C identity ledger: unknown event kind '${event.kind}'")
                    }
                }
            }
        }
    }

    for entry in stores.entries() {
        let (pair_key, store) = entry
        let extract = match extracts.get(pair_key) {
            some(found) => found,
            none => panic("C identity ledger: capture store '${pair_key}' has no extract")
        }
        if identity_event_same_identity(store, extract) == false {
            panic("C identity ledger: capture identity mismatch '${pair_key}'")
        }
        let edge = match edges.get(store.edge_id) {
            some(found) => found,
            none => panic("C identity ledger: capture references missing edge ${store.edge_id}")
        }
        if store.dest_slot != edge.source_slot ||
           store.parent_frame != edge.parent_frame ||
           store.child_frame != edge.child_frame ||
           extract.parent_frame != edge.parent_frame ||
           extract.child_frame != edge.child_frame {
            panic("C identity ledger: capture frame mismatch '${pair_key}'")
        }
    }
    for entry in extracts.entries() {
        let (pair_key, _extract) = entry
        if stores.contains_key(pair_key) == false {
            panic("C identity ledger: capture extract '${pair_key}' has no store")
        }
    }
    for entry in edges.entries() {
        let (edge_id, _edge) = entry
        let stores_for_edge = match store_indices.get(edge_id) {
            some(indices) => indices,
            none => set_new()
        }
        let extracts_for_edge = match extract_indices.get(edge_id) {
            some(indices) => indices,
            none => set_new()
        }
        if stores_for_edge.len() != extracts_for_edge.len() {
            panic("C identity ledger: edge ${edge_id} capture count mismatch")
        }
        let mut index = 1
        while index <= stores_for_edge.len() {
            if stores_for_edge.contains(index) == false ||
               extracts_for_edge.contains(index) == false {
                panic("C identity ledger: edge ${edge_id} capture indices are not contiguous")
            }
            index = index + 1
        }
    }
    for entry in loads.entries() {
        let (load_id, load) = entry
        let count = match load_call_counts.get(load_id) {
            some(found) => found,
            none => 0
        }
        if count != 1 {
            panic("C identity ledger: receiver load ${load_id} consumed ${count} times")
        }
        let mut matched_call = false
        for event in ctx.identity_events {
            if event.kind == "closure-call" && event.load_id == load_id {
                if event.parent_frame != load.parent_frame ||
                   event.source_slot != load.dest_slot ||
                   event.domain != "computed" ||
                   event.producer != load.kind {
                    panic("C identity ledger: load/call slot mismatch ${load_id}")
                }
                matched_call = true
            }
        }
        if matched_call == false {
            panic("C identity ledger: receiver load ${load_id} has no call")
        }
    }
    for entry in load_call_counts.entries() {
        let (load_id, _count) = entry
        if loads.contains_key(load_id) == false {
            panic("C identity ledger: closure call references missing load ${load_id}")
        }
    }
    for slot in exact_slots {
        if name_only_slots.contains(slot) {
            panic("C identity ledger: exact/name-only raw slot alias '${slot}'")
        }
    }
}

fn identity_ledger_escape(value: Str) -> Str {
    value.replace("%", "%25")
         .replace("|", "%7C")
         .replace("\n", "%0A")
         .replace("\r", "%0D")
}

pub fn c_identity_ledger_text(ctx: CCtx) -> Str {
    if ctx.identity_ledger_enabled == false {
        panic("C codegen: identity ledger requested while disabled")
    }
    validate_identity_ledger(ctx)
    let mut lines: List<Str> = ["RING-C-IDENTITY-LEDGER|1"]
    for event in ctx.identity_events {
        lines.push([
            "E", "${event.event_id}", identity_ledger_escape(event.kind),
            "${event.edge_id}", "${event.load_id}",
            identity_ledger_escape(event.parent_frame),
            identity_ledger_escape(event.child_frame),
            identity_ledger_escape(event.domain), "${event.def_id}",
            identity_ledger_escape(event.canonical_key),
            identity_ledger_escape(event.producer),
            identity_ledger_escape(event.source_slot),
            identity_ledger_escape(event.dest_slot),
            "${event.index}", "${event.arity}"
        ].join("|"))
    }
    "${lines.join("\n")}\n"
}

fn c_unique_local(mut ctx: CCtx, ring_name: Str) -> Str {
    let base = "r_${c_sanitize(ring_name)}"
    let mut cname = base
    let mut k = 2
    while ctx.used_locals.contains(cname) {
        cname = "${base}_${k}"
        k = k + 1
    }
    ctx.used_locals.insert(cname)
    cname
}

// ============================================================
// Nested function emission bracket (step 5) — the C analogue of the LLVM
// backend's builder-position save/restore.  Lambdas, dict getters, thunks and
// derived methods are synthesised MID-emission of another function: push the
// live per-function state, emit the nested function, assemble it into
// fn_defs, pop.  Module-wide counters (tmp/str/label) are NOT reset — names
// stay unique across functions (existing invariant).
// ============================================================

pub struct CEmitState {
    pub cur_decls: List<Str>,
    pub cur_body: List<Str>,
    pub used_locals: Set<Str>,
    pub named_values: Map<Str, Str>,
    pub name_only_slots: Map<Str, CNameOnlySlotRef>,
    pub value_slots_by_def_id: Map<Int, CExactSlotRef>,
    pub value_slots_by_slot_key: Map<Str, CExactSlotRef>,
    pub indent: Int,
    pub in_function: Bool,
    pub current_fn_name: Str,
    pub in_loop: Bool,
    pub loop_continue_stmt: Str,
    pub last_line: Int,
    pub last_file: Str,
    // Step 6: a nested function is a fresh C frame — a `return` inside a
    // lambda must NOT pop the enclosing function's catch frames (the frames
    // belong to the outer C stack frame).  Saved + cleared per nested
    // emission.  (Deliberate correctness deviation: the LLVM backend leaks
    // the enclosing stack into lambda bodies — see worker_feedback.)
    pub handle_cleanup_stack: List<CHandleCleanup>
}

pub fn c_push_fn(mut ctx: CCtx, fn_name: Str) -> CEmitState {
    let saved = CEmitState {
        cur_decls: ctx.cur_decls,
        cur_body: ctx.cur_body,
        used_locals: ctx.used_locals,
        named_values: ctx.named_values,
        name_only_slots: ctx.name_only_slots,
        value_slots_by_def_id: ctx.value_slots_by_def_id,
        value_slots_by_slot_key: ctx.value_slots_by_slot_key,
        indent: ctx.indent,
        in_function: ctx.in_function,
        current_fn_name: ctx.current_fn_name,
        in_loop: ctx.in_loop,
        loop_continue_stmt: ctx.loop_continue_stmt,
        last_line: ctx.last_line,
        last_file: ctx.last_file,
        handle_cleanup_stack: ctx.handle_cleanup_stack
    }
    ctx.cur_decls = []
    ctx.cur_body = []
    ctx.used_locals = set_new()
    ctx.named_values = map_new()
    ctx.name_only_slots = map_new()
    ctx.value_slots_by_def_id = map_new()
    ctx.value_slots_by_slot_key = map_new()
    ctx.indent = 1
    ctx.in_function = true
    ctx.current_fn_name = fn_name
    ctx.in_loop = false
    ctx.loop_continue_stmt = ""
    ctx.last_line = -1
    ctx.last_file = ""
    ctx.handle_cleanup_stack = []
    saved
}

// Assemble the nested function into fn_defs and restore the outer state.
// The caller pushes the prototype itself (params differ per synthesis kind).
pub fn c_pop_fn(mut ctx: CCtx, c_name: Str, params_str: Str, saved: CEmitState) {
    let mut def: List<Str> = []
    def.push("void* ${c_name}(${params_str}) {")
    for d in ctx.cur_decls { def.push(d) }
    for l in ctx.cur_body { def.push(l) }
    def.push("}")
    ctx.fn_defs.push(def.join("\n"))
    ctx.cur_decls = saved.cur_decls
    ctx.cur_body = saved.cur_body
    ctx.used_locals = saved.used_locals
    ctx.named_values = saved.named_values
    ctx.name_only_slots = saved.name_only_slots
    ctx.value_slots_by_def_id = saved.value_slots_by_def_id
    ctx.value_slots_by_slot_key = saved.value_slots_by_slot_key
    ctx.indent = saved.indent
    ctx.in_function = saved.in_function
    ctx.current_fn_name = saved.current_fn_name
    ctx.in_loop = saved.in_loop
    ctx.loop_continue_stmt = saved.loop_continue_stmt
    ctx.last_line = saved.last_line
    ctx.last_file = saved.last_file
    ctx.handle_cleanup_stack = saved.handle_cleanup_stack
}

// ============================================================
// String constants — explicit-length byte arrays (binary-safe, no strlen
// dependency in the EMITTED TEXT; plan §2.1: B-155-class corruption becomes
// eyeball-visible in the .c).  Content stays null-terminated to keep the
// ring_str_from_cstr zero-copy convention.
// ============================================================

// Escape one Ring string into a C string-literal body.  Printable ASCII
// passes through; everything else uses fixed-width 3-digit octal escapes
// (unambiguous even when the next source byte is a digit).
pub fn c_escape(s: Str) -> Str {
    let mut parts: List<Str> = []
    for i in 0..s.len() {
        let c = s.char_code_at(i).unwrap_or(0)
        if c == 34 {
            parts.push("\\\"")
        } else if c == 92 {
            parts.push("\\\\")
        } else if c == 10 {
            parts.push("\\n")
        } else if c == 9 {
            parts.push("\\t")
        } else if c == 13 {
            parts.push("\\r")
        } else if c >= 32 && c <= 126 {
            parts.push(s[i])
        } else {
            let hi = c / 64
            let mid = (c / 8) % 8
            let lo = c % 8
            parts.push("\\${hi}${mid}${lo}")
        }
    }
    parts.join("")
}

// Emit a fresh module-level string constant; returns its C name.
// One global per literal occurrence (mirrors the LLVM backend's fresh
// build_global_cstring per gen_str_lit — no dedup, byte-for-byte parity
// of allocation behaviour).
pub fn c_global_cstr(mut ctx: CCtx, s: Str) -> Str {
    let n = ctx.str_counter
    ctx.str_counter = n + 1
    let name = "ring_cstr_${n}"
    ctx.globals.push("static const char ${name}[${s.len() + 1}] = \"${c_escape(s)}\";")
    name
}

// Interned variant for compiler-synthesised messages (panic texts for
// unsupported constructs) — dedupes the potentially hundreds of identical
// stub messages emitted while step 4+ features are not yet ported.
pub fn c_interned_cstr(mut ctx: CCtx, s: Str) -> Str {
    match ctx.cstr_cache.get(s) {
        some(name) => name,
        none => {
            let name = c_global_cstr(ctx, s)
            ctx.cstr_cache.insert(s, name)
            name
        },
    }
}

// ============================================================
// Unsupported-construct stubs (steps 5-8 features reached through prelude
// bodies).  The emitted C compiles fine; executing the statement panics at
// runtime with a precise message.  Golden-subset cases never reach these.
// ============================================================

pub fn c_stub_stmt(mut ctx: CCtx, what: Str) {
    let g = c_interned_cstr(ctx, "ring-c backend: ${what} is not implemented")
    rt_use(ctx, "ring_panic", 1)
    rt_use(ctx, "ring_str_from_cstr", 1)
    c_emit(ctx, "ring_panic(ring_str_from_cstr(${g}));")
}

pub fn c_stub_expr(mut ctx: CCtx, what: Str) -> Str {
    c_stub_stmt(ctx, what)
    "RING_UNIT"
}

// ============================================================
// #line directives — map emitted C back to .ring source (default ON;
// --no-c-lines for human-readable output).
// ============================================================

pub fn c_line_directive(mut ctx: CCtx, span: Span) {
    if ctx.emit_lines == false { return }
    if ctx.in_function == false { return }
    let line = span.start.line
    let file = span.file
    if line == ctx.last_line && file == ctx.last_file { return }
    ctx.last_line = line
    ctx.last_file = file
    let esc = file.replace("\\", "\\\\")
    c_raw(ctx, "#line ${line} \"${esc}\"")
}

// ============================================================
// Perceus RC typeids: user types start at 64; List/Map keep their fixed
// runtime typeids.
// ============================================================

pub fn get_or_assign_c_typeid(mut ctx: CCtx, type_name: Str) -> Int {
    match ctx.type_to_typeid.get(type_name) {
        some(id) => id,
        none => {
            if type_name == "List" {
                ctx.type_to_typeid.insert(type_name, 4)
                return 4
            }
            if type_name == "Map" {
                ctx.type_to_typeid.insert(type_name, 5)
                return 5
            }
            let id = ctx.next_user_typeid
            ctx.next_user_typeid = id + 1
            ctx.type_to_typeid.insert(type_name, id)
            id
        },
    }
}

// ============================================================
// Runtime function prototypes.
// rt_use(name, arity) registers the prototype on first use; the assembled
// file prints them sorted by name (deterministic — audit #237 discipline).
// Known signatures match ring_runtime.cpp's extern "C" definitions.
// Unknown names (user/std `extern fn`s like ring_slot_read) fall back to the
// uniform boxed ABI: all params void*, returns void*.
// ============================================================

pub fn rt_use(mut ctx: CCtx, name: Str, arity: Int) {
    if ctx.rt_protos.contains_key(name) { return }
    let enc = match rt_sig(name) {
        some(s) => s,
        none => {
            let mut ps: List<Str> = []
            for _i in 0..arity { ps.push("p") }
            "${ps.join("")}>p"
        },
    }
    ctx.rt_protos.insert(name, sig_to_proto(name, enc))
}

// Insert a hand-written prototype verbatim (signatures the p/i/d/c encoding
// cannot express, e.g. ring_runtime_init(int, char**)).
pub fn rt_use_raw(mut ctx: CCtx, name: Str, proto: Str) {
    if ctx.rt_protos.contains_key(name) { return }
    ctx.rt_protos.insert(name, proto)
}

// True when `name` is a known ring_runtime.cpp symbol.  A colliding Ring
// function must be renamed — the LLVM backend gets this for free from LLVM's
// module-level symbol renaming; in C a duplicate definition is a hard link
// error.
pub fn is_runtime_symbol(name: Str) -> Bool {
    match rt_sig(name) {
        some(_) => true,
        none => false,
    }
}

// The declared arity of a known runtime function (used to NULL-pad calls the
// checker allows with fewer args, e.g. sb.line() — mirrors the LLVM backend's
// LLVMCountParams pad in gen_method_call).
pub fn rt_known_arity(name: Str) -> Int? {
    match rt_sig(name) {
        some(s) => {
            match s.index_of(">") {
                some(idx) => some(idx),
                none => none,
            }
        },
        none => none,
    }
}

fn ctype_of(ch: Str) -> Str {
    if ch == "p" { "void*" }
    else if ch == "e" { "EffectCtx*" }
    else if ch == "i" { "int64_t" }
    else if ch == "d" { "double" }
    else if ch == "c" { "const char*" }
    else { "void" }
}

// sig encoding: "<params>><ret>", one char per param: p=void*,
// e=EffectCtx*, i=int64_t, d=double, c=const char*; ret additionally v=void.
fn sig_to_proto(name: Str, enc: Str) -> Str {
    let sep = match enc.index_of(">") {
        some(i) => i,
        none => panic("C codegen: bad runtime signature encoding '${enc}' for ${name}"),
    }
    let params_enc = enc.slice(0, sep)
    let ret_enc = enc.slice(sep + 1, enc.len())
    let mut params: List<Str> = []
    for i in 0..params_enc.len() {
        params.push("${ctype_of(params_enc[i])} a${i}")
    }
    let params_str = if params.len() == 0 { "void" } else { params.join(", ") }
    "${ctype_of(ret_enc)} ${name}(${params_str});"
}

// Known runtime signatures (transcribed from declare_runtime_fns; kept in the
// same grouping/order for reviewability).
fn rt_sig(name: Str) -> Str? {
    // Boxing / unboxing
    if name == "ring_box_int" { return some("i>p") }
    if name == "ring_unbox_int" { return some("p>i") }
    if name == "ring_box_float" { return some("d>p") }
    if name == "ring_unbox_float" { return some("p>d") }
    if name == "ring_box_bool" { return some("i>p") }
    if name == "ring_unbox_bool" { return some("p>i") }
    if name == "ring_hash_combine" { return some("ii>i") }
    // Str
    if name == "ring_str_from_cstr" { return some("c>p") }
    if name == "ring_str_len" { return some("p>i") }
    if name == "ring_str_concat" { return some("pp>p") }
    if name == "ring_str_eq" { return some("pp>i") }
    if name == "ring_str_lt" { return some("pp>i") }
    if name == "ring_str_get" { return some("pi>p") }
    if name == "ring_str_contains" { return some("pp>i") }
    if name == "ring_str_starts_with" { return some("pp>i") }
    if name == "ring_str_ends_with" { return some("pp>i") }
    if name == "ring_str_slice" { return some("pii>p") }
    if name == "ring_str_split" { return some("pp>p") }
    if name == "ring_str_replace" { return some("ppp>p") }
    if name == "ring_str_trim" { return some("p>p") }
    if name == "ring_str_trim_start" { return some("p>p") }
    if name == "ring_str_trim_end" { return some("p>p") }
    if name == "ring_str_to_upper" { return some("p>p") }
    if name == "ring_str_to_lower" { return some("p>p") }
    if name == "ring_str_char_at" { return some("pi>p") }
    if name == "ring_str_char_code_at" { return some("pi>p") }
    if name == "ring_str_index_of" { return some("pp>p") }
    if name == "ring_str_last_index_of" { return some("pp>p") }
    if name == "ring_str_is_empty" { return some("p>i") }
    if name == "ring_str_pad_start" { return some("pip>p") }
    if name == "ring_str_pad_end" { return some("pip>p") }
    if name == "ring_str_repeat" { return some("pi>p") }
    if name == "ring_str_join" { return some("pp>p") }
    // StringBuilder (runtime std::string SB used by string interpolation)
    if name == "ring_sb_new" { return some(">p") }
    if name == "ring_sb_add" { return some("pp>p") }
    if name == "ring_sb_to_str" { return some("p>p") }
    if name == "ring_sb_len" { return some("p>i") }
    if name == "ring_sb_line" { return some("pp>p") }
    if name == "ring_sb_add_int" { return some("pi>p") }
    // Scalar to Str
    if name == "ring_int_to_str" { return some("i>p") }
    if name == "ring_float_to_str" { return some("d>p") }
    if name == "ring_bool_to_str" { return some("i>p") }
    // IO / process
    if name == "ring_print" { return some("p>p") }
    if name == "ring_eprintln" { return some("p>p") }
    if name == "ring_panic" { return some("p>p") }
    if name == "ring_exit" { return some("p>p") }
    if name == "ring_args" { return some(">p") }
    if name == "ring_cwd" { return some(">p") }
    // Memory / RC
    if name == "ring_alloc" { return some("ii>p") }
    if name == "ring_dup" { return some("p>v") }
    if name == "ring_drop" { return some("p>v") }
    if name == "ring_register_drop" { return some("ip>v") }
    if name == "ring_register_never_drop" { return some("i>v") }
    if name == "ring_const_intern" { return some("p>p") }
    if name == "ring_unit_intern" { return some("p>p") }
    if name == "ring_effect_ctx_empty" { return some(">e") }
    // List
    if name == "ring_list_new" { return some(">p") }
    if name == "ring_list_push" { return some("pp>p") }
    if name == "ring_list_get" { return some("pi>p") }
    if name == "ring_list_len" { return some("p>i") }
    if name == "ring_list_join" { return some("pp>p") }
    if name == "ring_list_concat" { return some("pp>p") }
    if name == "ring_list_slice" { return some("pii>p") }
    if name == "ring_list_reverse" { return some("p>p") }
    if name == "ring_list_sort" { return some("ppe>p") }
    if name == "ring_list_sort_bridge" { return some("ppe>p") }
    if name == "ring_list_pop" { return some("p>p") }
    if name == "ring_list_is_empty" { return some("p>i") }
    if name == "ring_list_first" { return some("p>p") }
    if name == "ring_list_last" { return some("p>p") }
    if name == "ring_list_map" { return some("pp>p") }
    if name == "ring_list_filter" { return some("pp>p") }
    if name == "ring_list_for_each" { return some("pp>p") }
    if name == "ring_list_set" { return some("pip>p") }
    if name == "ring_list_any" { return some("pp>i") }
    if name == "ring_list_all" { return some("pp>i") }
    if name == "ring_list_find" { return some("pp>p") }
    if name == "ring_list_flat_map" { return some("pp>p") }
    if name == "ring_list_shift" { return some("p>p") }
    if name == "ring_list_clear" { return some("p>p") }
    if name == "ring_list_extend" { return some("pp>p") }
    // B-152 P3 closure: Map operations are Ring functions/methods.  Only the
    // low-level slot/buffer/hash bridges remain runtime symbols.
    // Catch / raise (setjmp-based; used from step 6 on, listed for parity)
    if name == "ring_catch_push" { return some(">p") }
    if name == "ring_catch_get_buf" { return some("p>p") }
    if name == "ring_catch_pop" { return some(">v") }
    if name == "ring_catch_get_error" { return some("p>p") }
    if name == "ring_raise" { return some("p>v") }
    if name == "__ring_raise_fail" { return some("p>p") }
    // File IO / path
    if name == "ring_read_file" { return some("p>p") }
    if name == "ring_write_file" { return some("pp>p") }
    if name == "ring_file_exists" { return some("p>p") }
    if name == "ring_delete_file" { return some("p>p") }
    if name == "ring_path_join" { return some("pp>p") }
    if name == "ring_path_resolve" { return some("p>p") }
    if name == "ring_path_dirname" { return some("p>p") }
    if name == "ring_path_basename" { return some("p>p") }
    if name == "ring_path_extname" { return some("p>p") }
    // Parse
    if name == "ring_parse_int" { return some("p>p") }
    if name == "ring_parse_float" { return some("p>p") }
    // Misc
    if name == "ring_assert" { return some("ip>p") }
    if name == "ring_match_fail" { return some("piip>p") }
    // Trait dicts (step 5)
    if name == "ring_get_builtin_dict" { return some("p>p") }
    if name == "ring_cl_eq_int" || name == "ring_cl_ne_int" ||
       name == "ring_cl_eq_float" || name == "ring_cl_ne_float" ||
       name == "ring_cl_eq_str" || name == "ring_cl_ne_str" ||
       name == "ring_cl_eq_bool" || name == "ring_cl_ne_bool" ||
       name == "ring_cl_cmp_int" || name == "ring_cl_cmp_float" ||
       name == "ring_cl_cmp_str" || name == "ring_cl_cmp_bool" {
        return some("pppe>p")
    }
    if name == "ring_cl_debug_int" || name == "ring_cl_debug_float" ||
       name == "ring_cl_debug_str" || name == "ring_cl_debug_bool" ||
       name == "ring_cl_hash_int_export" ||
       name == "ring_cl_hash_str_export" ||
       name == "ring_cl_hash_bool_export" {
        return some("ppe>p")
    }
    // Option
    if name == "ring_Option_unwrap_or" { return some("pp>p") }
    if name == "ring_Option_unwrap" { return some("p>p") }
    if name == "ring_Option_is_some" { return some("p>i") }
    if name == "ring_Option_is_none" { return some("p>i") }
    if name == "ring_Option_map" { return some("ppe>p") }
    if name == "ring_Option_and_then" { return some("ppe>p") }
    if name == "ring_Option_unwrap_or_else" { return some("ppe>p") }
    if name == "ring_Option_to_fail" { return some("pp>p") }
    if name == "ring_Option_none" { return some(">p") }
    // Cell
    if name == "ring_Cell_new" { return some("p>p") }
    if name == "ring_Cell_get" { return some("p>p") }
    if name == "ring_Cell_set" { return some("pp>p") }
    if name == "ring_Cell_update" { return some("ppe>p") }
    // B-125 Ptr<T> primitives
    if name == "ring_raw_alloc" { return some("p>p") }
    if name == "ring_raw_dealloc" { return some("pp>v") }
    if name == "ring_ptr_copy" { return some("ppp>v") }
    none
}
