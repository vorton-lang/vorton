// ============================================================
// verify_rc.ring — B-104 D2: static Perceus RC leak/UAF verifier
// ============================================================
//
// A linear check over the POST-RC HIR (the output of perceus_transform),
// translating the Perceus well-formedness judgment (Koka POPL'21 "Perceus:
// Garbage Free Reference Counting with Reuse", §2.4 linear resource calculus:
// Δ | Γ ⊢ e — every owned variable is consumed exactly once, borrowed
// variables are never consumed) to Ring's clone-all-escape RC model
// (design.md §7.11).  Three judgments:
//
//   (1) LEAK: every OWNED value — a fresh production (constructor / literal /
//       non-borrow call / arith box / Clone dup) or an owned binding — is
//       consumed EXACTLY ONCE: by an escape (struct/variant field, list/tuple
//       element, sink arg, range bound, assign/let slot, return) or by an
//       explicit HStmt::Drop.  An owned value nobody consumes is a leak.
//   (2) UAF: every Drop targets an owned, live value — dropping a borrow
//       (parameter, pattern projection, for-in binding, non-droppable init)
//       or an already-dropped/moved value is a use-after-free; so is an
//       ESCAPE of a bare borrow (an owner-bearing value stored without a
//       Clone) and any read after drop/move.
//   (3) BALANCE: sibling branches leave enclosing binding states identical
//       (the #134 per-path imbalance class, caught statically), and loop
//       bodies are state-neutral for enclosing bindings.
//
// Passing = a compile-time proof of 0 leaks + 0 UAF **at the HIR level**,
// modulo (a) the DOCUMENTED EXEMPTION CLASSES below — D1's deliberate
// leak-direction conservatisms, each reported (non-fatal) and counted — and
// (b) the CODEGEN-LEVEL BOUNDARY: drops that exist only in codegen-emitted
// code and are invisible in HIR (see rc_verify_boundary_note).
//
// ── Exemption classes (leak-direction, documented; non-fatal) ─────────────
//   (x-fold-arg retired 2026-06-12 — #150 closed by the ring_list_fold
//    empty-path dup; fold args materialise like any call args now.)
//   (x-andor retired 2026-06-13 — B-104 D7: andor_lower rewrites `&&`/`||`
//    to IfExpr at checker end; the phi either materialises + scope-end-drops
//    (all-fresh arms) or falls under the existing x-cf-value posture (mixed
//    arms).  No And/Or BinOp reaches post-RC HIR.)
//   x-cf-value          a control-flow value (if/match/block tail) that is an
//                       owned temporary in a non-consuming position (discarded
//                       statement value / borrow position / mixed-ownership
//                       init — W3a's non-blanket recursion; D1 保守保留).
//   x-effect-value      EffectOp / TryCatch / HandleExpr values are never
//                       owned by their binding (abort-path aliasing, B-002).
//   x-overwrite-field   `s.f = v` overwrites without dropping the old field
//                       value (codegen L0 field-store convention; the B-109 ①
//                       struct-field reassignment leak class).
//   x-overwrite-var     non-scalar mut-var reassignment leaks the old value
//                       (W4 covers scalars only; non-scalar lvalues deferred).
//   x-overwrite-boxed   auto-boxed mut cell writes leak the old cell value
//                       (B-091: the write mutates cell.value, no drop).
//   x-overwrite-param   assignment to a (mut) parameter overwrites a borrow.
//   x-spread            struct/variant spread copies the source's field
//                       pointers raw (no dup) — leak-on-spread, L1 posture.
//   x-discard           `let _ = <owned>` discards without a drop.
//   NOT REPORTED (excluded from the account by rule, design.md §7.11):
//     Unit-typed values (D1 rule ②), extern-handle / contains-extern values
//     (D1 rule ① / audit #139), TypeVar/ErrorType values (unknown-ownership
//     guard, audit #149), NeverType values (no value ever exists).
//
// ── Codegen-level boundary (HIR cannot see these; documented, not findings) ─
//   * while-cond / match-guard Bool boxes: dropped by codegen post-unbox
//     (emit_while / emit_match_arm_body, gated on is_fresh_owned_bool_value —
//     the verifier ACCEPTS an owned condition value exactly when that
//     predicate is true, i.e. when the codegen drop is guaranteed).
//   * Set-iteration conversion list (for-in over a Set lowers through a
//     temporary list; dropped by codegen — Stage 2 F round).
//   * range-loop counter/bound boxes (emit_for_in_range_direct drops them —
//     B-104b); a literal RangeExpr iterable is therefore accepted inline.
//   * String interpolation SB + intermediate strings: gen_string_interp
//     drops the SB after ring_sb_to_str, and drops each codegen-synthesised
//     intermediate string (literal parts from ring_str_from_cstr, non-Str
//     expression parts from convert_to_str) after ring_sb_add.  Str-typed
//     expression parts are NOT dropped here (pass-through — D1 manages them).
//   (the former "#151 codegen-synthesised Eq/Ord dicts" entry is RETIRED —
//    B-104 D4 made dict evidence first-class: static dicts are never-drop
//    module singletons (borrows, outside the account by construction) and
//    dynamic wrapped dicts are HIR-visible DictConstruct locals in the normal
//    LEAK/UAF/BALANCE account above.  No exemption class replaces it.)
//   * handler evidence structs (B-096: dropped at codegen level by
//     emit_evidence_drops, invisible to this HIR check) / catch closures
//     and closure env capture dups (balanced by drop_closure_env).
//   * abort paths: fail.raise / handler-abort longjmp skips the in-flight
//     scope-end drops at runtime — a DYNAMIC effect invisible to (and out of
//     scope for) this static check; design-accepted leak, B-002.
//
// ── What this verifier deliberately does NOT re-derive ─────────────────────
//   The per-function return-mode classification of ring_runtime.cpp builtins
//   (FRESH/BORROW/SCALAR/NULL-NEVER) is the shared ground truth established
//   by B-103 (evidence table in perceus.ring, predicates in hir.ring).  The
//   verifier consumes it via is_borrow_returning_call / is_str_index — its
//   independent value is the structural ACCOUNTING
//   (exactly-once over every position and path), not the leaf table, whose
//   completeness is validated by ASan (the B-103 safety net).
//
// v_droppable_init below mirrors perceus.is_droppable_init for POST-RC HIR
// (Block tails may have been hoisted into `let __rc_scope_N` + Ident tail) —
// keep the two in sync; a drift shows up immediately as self-verify findings.

use ast::{Span, Position}
use types::{Type}
use hir::{HDecl, HStmt, HExpr, HParam, HProgram, HMatchArm, HStructFieldInit,
    HStringInterpPart, HEffectHandler, hexpr_type, hexpr_span,
    is_rc_excluded_type, type_contains_extern_handle,
    is_borrow_returning_call, is_fresh_owned_bool_value,
    is_nullary_variant_ctor_ident, is_materialized_fn_value,
    is_exact_direct_call_ident}
use perceus::{rc_name_skippable, is_str_index, is_unresolved_var_type,
    sink_arg_indices, is_variant_constructor_call, expr_diverges, stmt_diverges,
    is_scalar_type, is_owned_slot_result_call, is_owned_slot_result_callee,
    is_materializable_fn_value}

// Value classes (what an expression's value IS, ownership-wise)
const CLS_OWNED: Int = 0     // fresh / dup'd — somebody must consume it exactly once
const CLS_BORROW: Int = 1    // aliases a reference owned elsewhere
const CLS_EXCLUDED: Int = 2  // outside the RC account (Unit / extern / TypeVar / Never)
const CLS_OPAQUE: Int = 3    // ownership not statically determined (effect
                             // values, mixed control flow) — leak-direction

// Consumption modes (what the PARENT position does with the value)
const M_CONSUMED: Int = 0    // parent takes ownership (escape/sink/slot)
const M_BORROWED: Int = 1    // parent only reads

// Binding kinds
const K_OWNED: Int = 0       // droppable owned local — exactly-once consumption
const K_BORROW: Int = 1      // param / pattern projection / for-in binding / destructure
const K_NONOWNED: Int = 2    // local the pass deliberately does not drop
const K_CAPTURE: Int = 3     // outer exact binding, borrowed in nested callable

// Binding states (owned bindings)
const S_LIVE: Int = 0
const S_DROPPED: Int = 1
const S_MOVED: Int = 2

pub struct RcFinding {
    pub class: Str,
    pub fatal: Bool,
    pub message: Str,
    pub fn_name: Str,
    pub span: Span
}

struct VCtx {
    names: List<Str>,
    def_ids: List<Int>,
    kinds: List<Int>,
    states: List<Int>,
    spans: List<Span>,
    frames: List<Int>,
    loop_bases: List<Int>,
    boxed: Set<Int>,
    externs: Set<Str>,
    findings: List<RcFinding>,
    fn_name: Str
}

// ============================================================
// Entry points
// ============================================================

pub fn verify_rc_program(program: HProgram) -> List<RcFinding> {
    // B-144: use program-level extern type names (global set, covers use-imports).
    let externs = program.extern_type_names
    let mut findings: List<RcFinding> = []
    verify_decls(program.decls, program.boxed_vars, externs, findings)
    findings
}

pub fn rc_fatal_count(findings: List<RcFinding>) -> Int {
    let mut n = 0
    for f in findings { if f.fatal { n = n + 1 } }
    n
}

pub fn rc_verify_boundary_note() -> Str {
    "note: HIR-level proof. Codegen-level drops are outside this check (documented boundary): while-cond/guard box (codegen post-unbox drop), Set-iteration list + range-loop bounds (codegen drops), string interpolation SB + intermediate strings (gen_string_interp drops), handler evidence (B-096 codegen emit_evidence_drops) / catch closures, abort paths (longjmp skips scope drops — B-002)."
}

// Format findings: fatal lines always one-per-finding; exempt (documented)
// classes aggregate to per-class counts unless `strict`.
pub fn format_rc_findings(findings: List<RcFinding>, strict: Bool) -> Str {
    let mut lines: List<Str> = []
    let mut class_names: List<Str> = []
    let mut class_counts: List<Int> = []
    for f in findings {
        if f.fatal || strict {
            lines.push("${f.span.file}:${f.span.start.line}:${f.span.start.column} rc-verify[${f.class}] ${f.message}")
        }
        if f.fatal == false {
            let mut idx = 0 - 1
            let mut i = 0
            while i < class_names.len() {
                if class_names[i] == f.class { idx = i }
                i = i + 1
            }
            if idx >= 0 {
                class_counts.set(idx, class_counts[idx] + 1)
            } else {
                class_names.push(f.class)
                class_counts.push(1)
            }
        }
    }
    let fatal = rc_fatal_count(findings)
    let exempt = findings.len() - fatal
    if exempt > 0 {
        let mut parts: List<Str> = []
        let mut i = 0
        while i < class_names.len() {
            parts.push("${class_names[i]}=${class_counts[i]}")
            i = i + 1
        }
        let joined = parts.join(" ")
        lines.push("rc-verify exempt classes: ${joined}")
    }
    lines.push("RC verify: ${fatal} errors, ${exempt} exempt (documented) findings")
    lines.push(rc_verify_boundary_note())
    lines.join("\n")
}

fn verify_decls(decls: List<HDecl>, boxed: Set<Int>, externs: Set<Str>, mut findings: List<RcFinding>) {
    for d in decls {
        match d {
            HDecl::Fn { name, params, body, .. } => {
                v_fn_scope(params, body, name, boxed, externs, findings)
            },
            HDecl::Impl { methods, .. } => {
                verify_decls(methods, boxed, externs, findings)
            },
            HDecl::Test { description, body, .. } => {
                let no_params: List<HParam> = []
                v_fn_scope(no_params, body, "test ${description}", boxed, externs, findings)
            },
            HDecl::Const { name, init, .. } => {
                // A const owns its value for the program lifetime — the init is
                // consumed by the global slot, never dropped.  Not a leak.
                let mut ctx = v_new_ctx(boxed, externs, findings, "const ${name}")
                let _ = v_consume(init, ctx)
            },
            HDecl::ModBlock { decls: mod_decls, .. } => {
                verify_decls(mod_decls, boxed, externs, findings)
            },
            HDecl::Struct { .. } => {},
            HDecl::Enum { .. } => {},
            HDecl::Effect { .. } => {},
            HDecl::Trait { .. } => {},
            HDecl::ExternFn { .. } => {},
            HDecl::ExternType { .. } => {},
            HDecl::TypeAlias { .. } => {},
        }
    }
}

// A function/test/lambda/handler body: fresh scope, params borrow, body value
// is consumed by the caller (clone-all-escape return convention).
fn v_fn_scope(params: List<HParam>, body: HExpr, label: Str, boxed: Set<Int>, externs: Set<Str>, mut findings: List<RcFinding>) {
    let mut ctx = v_new_ctx(boxed, externs, findings, label)
    v_push_frame(ctx)
    for p in params {
        let def_id = v_required_def_id(
            p.def_id, "parameter '${p.name}'")
        v_bind(ctx, p.name, def_id, K_BORROW, synthetic_vspan())
    }
    v_callable_body(body, ctx)
    v_pop_frame(ctx)
}

fn v_child_scope(
    params: List<HParam>, body: HExpr, label: Str, parent: VCtx
) {
    let mut ctx = v_new_ctx(
        parent.boxed, parent.externs, parent.findings, label)
    v_push_frame(ctx)
    let mut index = 0
    while index < parent.names.len() {
        v_bind(ctx, parent.names[index], parent.def_ids[index],
            K_CAPTURE, parent.spans[index])
        index = index + 1
    }
    for p in params {
        let def_id = v_required_def_id(
            p.def_id, "parameter '${p.name}'")
        v_bind(ctx, p.name, def_id, K_BORROW, synthetic_vspan())
    }
    v_callable_body(body, ctx)
    v_pop_frame(ctx)
}

fn v_callable_body(body: HExpr, mut ctx: VCtx) {
    match body {
        HExpr::Block { .. } => {
            v_block(body, M_CONSUMED, ctx)
        },
        _ => {
            v_consume(body, ctx)
            ((0, false))
        },
    }
}

fn v_new_ctx(boxed: Set<Int>, externs: Set<Str>, mut findings: List<RcFinding>, label: Str) -> VCtx {
    let names: List<Str> = []
    let def_ids: List<Int> = []
    let kinds: List<Int> = []
    let states: List<Int> = []
    let spans: List<Span> = []
    let frames: List<Int> = []
    let loop_bases: List<Int> = []
    VCtx {
        names: names, def_ids: def_ids,
        kinds: kinds, states: states, spans: spans,
        frames: frames, loop_bases: loop_bases,
        boxed: boxed, externs: externs, findings: findings, fn_name: label
    }
}

fn synthetic_vspan() -> Span {
    let pos = Position { line: 0, column: 0, offset: 0 }
    Span { file: "<verify-rc>", start: pos, end: pos }
}

fn v_required_def_id(def_id: Int?, label: Str) -> Int {
    match def_id {
        some(id) => id,
        none => panic("RC verifier ${label} has no exact DefId")
    }
}

// ============================================================
// Binding environment
// ============================================================

fn v_report(mut ctx: VCtx, class: Str, fatal: Bool, msg: Str, span: Span) {
    ctx.findings.push(RcFinding {
        class: class, fatal: fatal,
        message: "in ${ctx.fn_name}: ${msg}",
        fn_name: ctx.fn_name, span: span
    })
}

fn v_push_frame(mut ctx: VCtx) {
    ctx.frames.push(ctx.names.len())
}

fn v_pop_frame(mut ctx: VCtx) {
    let base = match ctx.frames.pop() { some(b) => b, none => 0 }
    while ctx.names.len() > base {
        ctx.names.pop()
        ctx.def_ids.pop()
        ctx.kinds.pop()
        ctx.states.pop()
        ctx.spans.pop()
    }
}

fn v_frame_base(ctx: VCtx) -> Int {
    let n = ctx.frames.len()
    if n == 0 { 0 } else { ctx.frames[n - 1] }
}

// Exact binding index, or -1 for a declaration/global not owned by this scope.
fn v_lookup(ctx: VCtx, def_id: Int) -> Int {
    let mut i = ctx.names.len() - 1
    let mut found = 0 - 1
    while i >= 0 && found < 0 {
        if ctx.def_ids[i] == def_id { found = i }
        i = i - 1
    }
    found
}

fn v_lookup_name(ctx: VCtx, name: Str) -> Int {
    let mut index = ctx.names.len() - 1
    while index >= 0 {
        if ctx.names[index] == name { return index }
        index = index - 1
    }
    0 - 1
}

fn v_bind(
    mut ctx: VCtx, name: Str, def_id: Int, kind: Int, span: Span
) {
    if rc_name_skippable(name) {
        return
    }
    let idx = v_lookup(ctx, def_id)
    if idx >= 0 {
        panic("RC verifier duplicate binder DefId ${def_id} for '${name}'")
    } else {
        ctx.names.push(name)
        ctx.def_ids.push(def_id)
        ctx.kinds.push(kind)
        ctx.states.push(S_LIVE)
        ctx.spans.push(span)
    }
}

fn v_snapshot(ctx: VCtx) -> List<Int> {
    ctx.states.concat([])
}

fn v_restore(mut ctx: VCtx, snap: List<Int>) {
    let mut i = 0
    while i < ctx.states.len() && i < snap.len() {
        ctx.states.set(i, snap[i])
        i = i + 1
    }
}

fn v_states_equal(a: List<Int>, b: List<Int>, upto: Int) -> Bool {
    let mut i = 0
    let mut eq = true
    while i < upto && i < a.len() && i < b.len() {
        if a[i] != b[i] { eq = false }
        i = i + 1
    }
    eq
}

// ============================================================
// Type-level account exclusion (design.md §7.11 D1 rules ①② + #149 guard)
// ============================================================

fn v_type_excluded(ty: Type, externs: Set<Str>) -> Bool {
    if is_rc_excluded_type(ty, externs) {
        true
    } else if is_unresolved_var_type(ty) {
        true
    } else {
        match ty {
            Type::NeverType => true,
            _ => false,
        }
    }
}

// ============================================================
// POST-RC droppable-init classification
// ============================================================
//
// Mirror of perceus.is_droppable_init (the pass's PRE-RC binding-drop
// decision), adapted to POST-RC shapes — the ONE structural difference: a
// dropping block's tail has been hoisted by rc_block_inner into a fresh
// `let __rc_scope_N = <escape-processed tail>` and the syntactic tail is a
// bare Ident, so a Block-tail Ident classifies via the init of its exact DefId
// among the block's direct statements (the hoist), exactly
// like hir.is_fresh_owned_bool_value's post-RC Block arm.  (The pass-side
// `Ident => true` arm means "owner-bearing, will be Clone-wrapped at the
// escape"; post-RC that Clone is visible directly.)  KEEP IN SYNC with
// perceus.is_droppable_init — a drift shows up as self-verify findings.
fn v_droppable_init(init: HExpr, externs: Set<Str>) -> Bool {
    let ty = hexpr_type(init)
    if is_rc_excluded_type(ty, externs) {
        return false
    }
    if type_contains_extern_handle(ty, externs) {
        return false
    }
    // Exact slot ABI leaf: read/take results are owned even when an impl-level
    // K/V remains an unnamed TypeVar after zonk.
    if is_owned_slot_result_call(init) {
        return true
    }
    // A post-RC Clone is an explicit ring_dup and therefore owns its result;
    // do not let the audit #149 TypeVar guard erase that ownership proof.
    match init {
        HExpr::Clone { .. } => return true,
        HExpr::Take { .. } => return true,
        _ => {}
    }
    if is_unresolved_var_type(ty) {
        return false
    }
    if is_materialized_fn_value(init) {
        return true
    }
    match init {
        HExpr::Ident { .. } => true,
        HExpr::FieldAccess { .. } => true,
        HExpr::IndexExpr { .. } => true,
        HExpr::StructLit { .. } => true,
        HExpr::NamedVariantConstruct { .. } => true,
        HExpr::ListLit { .. } => true,
        HExpr::TupleLit { .. } => true,
        HExpr::RangeExpr { .. } => true,
        HExpr::Lambda { .. } => true,
        HExpr::StringInterp { .. } => true,
        HExpr::IntLit { .. } => true,
        HExpr::FloatLit { .. } => true,
        HExpr::StrLit { .. } => true,
        HExpr::BoolLit { .. } => true,
        HExpr::Clone { .. } => true,
        HExpr::Take { .. } => true,
        HExpr::Call { .. } => true,
        // B-104 D4: a dict construction is fresh-owned (mirrors
        // perceus.is_droppable_init) — the dict_lower binding is dropped at
        // scope end (runtime drop_dict).
        HExpr::DictConstruct { .. } => true,
        // B-104 D7: `&&`/`||` are lowered to IfExpr before RC — every BinOp
        // here is eager arith/compare with a fresh boxed result.
        HExpr::BinOp { .. } => true,
        HExpr::UnaryOp { .. } => true,
        HExpr::IfExpr { then_branch, else_branch, .. } => {
            match else_branch {
                none => false,
                some(eb) => v_droppable_branch(then_branch, externs) && v_droppable_branch(eb, externs),
            }
        },
        HExpr::MatchExpr { arms, .. } => {
            let mut all = arms.len() > 0
            for arm in arms {
                if v_droppable_branch(arm.body, externs) == false { all = false }
            }
            all
        },
        HExpr::Block { stmts, tail, .. } => {
            match tail {
                some(t) => match t {
                    // POST-RC hoisted tail: classify the hoist binding's init.
                    HExpr::Ident { def_id, .. } => match def_id {
                        some(id) => match v_block_local_init(stmts, id) {
                            some(hi) => v_droppable_init(hi, externs),
                            none => true
                        },
                        none => false
                    },
                    _ => v_droppable_init(t, externs),
                },
                none => false,
            }
        },
        _ => false,
    }
}

fn v_droppable_branch(body: HExpr, externs: Set<Str>) -> Bool {
    if expr_diverges(body) {
        true
    } else {
        match body {
            HExpr::Block { .. } => v_droppable_init(body, externs),
            _ => v_droppable_init(body, externs),
        }
    }
}

// The init of the exact direct Let/Var binding `def_id` in a statement list
// (post-RC hoist resolution; mirrors hir.block_local_init).
fn v_block_local_init(stmts: List<HStmt>, def_id: Int) -> HExpr? {
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

// ============================================================
// Position handlers
// ============================================================

// CONSUMED position: the parent takes ownership.  A bare BORROW here means the
// pass escaped an owner-bearing value without a Clone — the sink's later drop
// frees a reference owned elsewhere (UAF direction).
fn v_consume(expr: HExpr, mut ctx: VCtx) -> Int {
    let cls = v_expr(expr, M_CONSUMED, ctx)
    if cls == CLS_BORROW {
        v_report(ctx, "uaf-escaped-borrow", true,
            "a borrowed value escapes into an owning position without a Clone", hexpr_span(expr))
    }
    cls
}

// BORROWED position: the parent only reads.  An OWNED value here has no
// consumer — a leak.  `exempt` names the documented exemption class; "" means
// the position is supposed to be fully covered by the ANF pass → fatal.
fn v_borrow(expr: HExpr, exempt: Str, mut ctx: VCtx) -> Int {
    let missed_materialization =
        exempt == "" && is_materializable_fn_value(expr, ctx.externs)
    let cls = v_expr(expr, M_BORROWED, ctx)
    if missed_materialization {
        v_report(ctx, "leak-temp", true,
            "fresh callable control-flow value survived ANF in a read position", hexpr_span(expr))
    } else if cls == CLS_OWNED {
        if exempt == "" {
            v_report(ctx, "leak-temp", true,
                "owned temporary is never consumed (no binding, no drop) in a read position", hexpr_span(expr))
        } else {
            v_report(ctx, exempt, false,
                "owned value in a non-consuming position (documented leak class)", hexpr_span(expr))
        }
    }
    cls
}

// CONDITION position (while-cond / match-guard): the only positions where an
// owned value may legitimately stay inline — codegen drops the Bool box right
// after its unbox, gated on is_fresh_owned_bool_value (Stage 2 E round).  The
// verifier accepts an owned condition exactly when that predicate certifies
// the codegen drop; anything else owned here is a real gap.
fn v_cond(expr: HExpr, mut ctx: VCtx) {
    let cls = v_expr(expr, M_BORROWED, ctx)
    if cls == CLS_OWNED {
        if is_fresh_owned_bool_value(expr) == false {
            v_report(ctx, "leak-temp", true,
                "owned condition value not covered by the codegen post-unbox drop", hexpr_span(expr))
        }
    }
}

// ============================================================
// Expressions
// ============================================================

fn v_expr(expr: HExpr, mode: Int, mut ctx: VCtx) -> Int {
    let nullary_variant_ctor = is_nullary_variant_ctor_ident(expr)
    let materialized_fn_value = is_materialized_fn_value(expr)
    match expr {
        HExpr::IntLit { ty, .. } => v_cls_of_fresh(ty, ctx.externs),
        HExpr::FloatLit { ty, .. } => v_cls_of_fresh(ty, ctx.externs),
        HExpr::StrLit { ty, .. } => v_cls_of_fresh(ty, ctx.externs),
        HExpr::BoolLit { ty, .. } => v_cls_of_fresh(ty, ctx.externs),

        HExpr::Ident { name, def_id, ty, span, .. } => {
            // Inference represents a fieldless enum construction as an Ident,
            // but both native backends call its zero-argument constructor.  It
            // is therefore a fresh owned production, not a binding/global read.
            if nullary_variant_ctor || materialized_fn_value {
                v_cls_of_fresh(ty, ctx.externs)
            } else {
                v_ident(name, def_id, ty, span, mode, ctx)
            }
        },

        HExpr::BinOp { left, right, ty, .. } => {
            // Eager arith/compare: operands are consuming-borrows (the op
            // unboxes them; post-ANF they are materialised Idents/borrows).
            // `&&`/`||` never reach post-RC HIR (B-104 D7: andor_lower rewrites
            // them to IfExpr at checker end) — an unexpected one would surface
            // here as a leak-temp finding on its owned RHS.
            v_borrow(left, "", ctx)
            v_borrow(right, "", ctx)
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::UnaryOp { operand, ty, .. } => {
            v_borrow(operand, "", ctx)
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::Call { callee, args, ty, .. } => {
            // A final-zonk marked syntactic Ident uses the direct ABI and is
            // not a wrapper value in Call.callee position.  The exact DefId
            // must remain global: a local/capture marker is an invariant bug,
            // never permission to skip its ownership account.
            if is_exact_direct_call_ident(callee) {
                let direct_def_id = match callee {
                    HExpr::Ident { def_id: some(id), .. } => id,
                    _ => panic("RC verifier direct-call marker lost exact Ident")
                }
                if v_lookup(ctx, direct_def_id) >= 0 {
                    panic("RC verifier direct-call marker DefId ${direct_def_id} is local/captured")
                }
            } else {
                // ANF materialises every other fresh callee (including
                // Call-produced closures). Any owned callee still inline is
                // therefore a fatal accounting gap.
                let _ = v_borrow(callee, "", ctx)
            }
            let ctor = is_variant_constructor_call(callee, ty)
            let sinks = sink_arg_indices(callee, args.len())
            let owned_slot_result = args.len() == 2 && is_owned_slot_result_callee(callee)
            let mut i = 0
            for a in args {
                if ctor || v_list_has_int(sinks, i) {
                    v_consume(a, ctx)
                } else {
                    v_borrow(a, "", ctx)
                }
                i = i + 1
            }
            if owned_slot_result {
                CLS_OWNED
            } else if is_borrow_returning_call(callee) {
                CLS_BORROW
            } else {
                v_cls_of_fresh(ty, ctx.externs)
            }
        },

        HExpr::FieldAccess { receiver, ty, .. } => {
            v_borrow(receiver, "", ctx)
            if v_type_excluded(ty, ctx.externs) { CLS_EXCLUDED } else { CLS_BORROW }
        },

        // B-104 D4: a dict construction is a FRESH owned TUPLE-of-closures.  It
        // is a leaf — its inner DictRefs are borrows of dict params / locals /
        // module singletons (no sub-expressions to account).  It enters the
        // normal LEAK/UAF/BALANCE account: dict_lower binds it via `let
        // __ring_dictlocal_N`, perceus scope-end-drops the binding (exactly-once
        // consumption); an unconsumed construct is reported like any owned temp.
        HExpr::DictConstruct { ty, .. } => v_cls_of_fresh(ty, ctx.externs),

        HExpr::IndexExpr { receiver, index, ty, .. } => {
            v_borrow(receiver, "", ctx)
            v_borrow(index, "", ctx)
            if v_type_excluded(ty, ctx.externs) {
                CLS_EXCLUDED
            } else {
                // D1 rule ③: str[i] allocates a fresh 1-char string; list/map
                // indexing returns a borrowed element pointer.
                if is_str_index(receiver) { v_cls_of_fresh(ty, ctx.externs) } else { CLS_BORROW }
            }
        },

        HExpr::StructLit { fields, spread, ty, .. } => {
            for f in fields { v_consume(f.value, ctx) }
            match spread {
                some(s) => { v_borrow(s, "x-spread", ctx) },
                none => CLS_EXCLUDED,
            }
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::NamedVariantConstruct { fields, spread, ty, .. } => {
            for f in fields { v_consume(f.value, ctx) }
            match spread {
                some(s) => { v_borrow(s, "x-spread", ctx) },
                none => CLS_EXCLUDED,
            }
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::ListLit { elements, ty, .. } => {
            for e in elements { v_consume(e, ctx) }
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::TupleLit { elements, ty, .. } => {
            for e in elements { v_consume(e, ctx) }
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::RangeExpr { start, end, ty, .. } => {
            v_consume(start, ctx)
            v_consume(end, ctx)
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::StringInterp { parts, ty, .. } => {
            for p in parts {
                match p {
                    HStringInterpPart::Expression(e) => { v_borrow(e, "", ctx) },
                    HStringInterpPart::Literal(s) => 0,
                }
            }
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::Lambda { params, body, ty, .. } => {
            // Fresh function scope.  Captures are dup'd by gen_lambda at
            // construction and released by drop_closure_env (balanced — B-098
            // closure model). Seed exact outer identities as borrowed capture
            // slots so a stripped/mismatched capture DefId fails loud.
            v_child_scope(params, body, "${ctx.fn_name}/<lambda>", ctx)
            v_cls_of_fresh(ty, ctx.externs)
        },

        HExpr::Clone { inner, ty, .. } => {
            v_expr(inner, M_BORROWED, ctx)
            // Clone is an explicit ring_dup.  Unit/extern exclusions still
            // apply, but an unnamed TypeVar result remains provably owned.
            if is_rc_excluded_type(ty, ctx.externs)
                || type_contains_extern_handle(ty, ctx.externs) {
                CLS_EXCLUDED
            } else {
                CLS_OWNED
            }
        },

        HExpr::Take { source, ty, .. } => {
            v_expr(source, M_BORROWED, ctx)
            if is_rc_excluded_type(ty, ctx.externs) ||
               type_contains_extern_handle(ty, ctx.externs) {
                CLS_EXCLUDED
            } else {
                CLS_OWNED
            }
        },

        HExpr::Block { .. } => {
            let r = v_block(expr, mode, ctx)
            r.0
        },

        HExpr::IfExpr { condition, then_branch, else_branch, ty, span, .. } => {
            v_borrow(condition, "", ctx)
            let snap0 = v_snapshot(ctx)
            let rt = v_cf_branch(then_branch, mode, ctx)
            let snap_t = v_snapshot(ctx)
            v_restore(ctx, snap0)
            let re = match else_branch {
                some(eb) => v_cf_branch(eb, mode, ctx),
                none => ((CLS_EXCLUDED, false)),
            }
            let snap_e = v_snapshot(ctx)
            v_merge_two(ctx, rt.1, snap_t, re.1, snap_e, snap0, span)
            v_cf_class(ty, [rt, re], mode, ctx)
        },

        HExpr::MatchExpr { scrutinee, arms, ty, span, .. } => {
            v_borrow(scrutinee, "", ctx)
            let snap0 = v_snapshot(ctx)
            let mut results: List<(Int, Bool)> = []
            let mut ref_snap: List<Int> = []
            let mut have_ref = false
            for arm in arms {
                v_restore(ctx, snap0)
                v_push_frame(ctx)
                for binding in arm.bindings {
                    v_bind(ctx, binding.name, binding.def_id,
                        K_BORROW, arm.span)
                }
                match arm.guard {
                    some(g) => { v_cond(g, ctx) },
                    none => {},
                }
                let r = v_cf_branch(arm.body, mode, ctx)
                v_pop_frame(ctx)
                results.push(r)
                if r.1 == false {
                    if have_ref {
                        let cur = v_snapshot(ctx)
                        if v_states_equal(ref_snap, cur, snap0.len()) == false {
                            v_report(ctx, "rc-imbalance", true,
                                "match arms leave enclosing RC binding states imbalanced (#134 class)", span)
                        }
                    } else {
                        ref_snap = v_snapshot(ctx)
                        have_ref = true
                    }
                }
            }
            if have_ref { v_restore(ctx, ref_snap) } else { v_restore(ctx, snap0) }
            v_cf_class(ty, results, mode, ctx)
        },

        HExpr::TryCatch { body, arms, ty, span, .. } => {
            // The try/catch value is never owned by its consumer (abort-path
            // aliasing — B-002; is_droppable_init excludes TryCatch).  Arms run
            // from an aborted mid-body state: approximate with the entry state
            // and discard their state effects.
            // #167: after each arm, check that enclosing owned bindings were not
            // dropped/moved — a catch arm that consumes an outer binding causes
            // double-free (scope-end will drop it again).
            let snap0 = v_snapshot(ctx)
            v_cf_branch(body, mode, ctx)
            let snap_body = v_snapshot(ctx)
            for arm in arms {
                v_restore(ctx, snap0)
                v_push_frame(ctx)
                for binding in arm.bindings {
                    v_bind(ctx, binding.name, binding.def_id,
                        K_BORROW, arm.span)
                }
                match arm.guard {
                    some(g) => { v_cond(g, ctx) },
                    none => {},
                }
                v_cf_branch(arm.body, mode, ctx)
                v_pop_frame(ctx)
                // #167: detect catch arm altering enclosing binding state
                let snap_arm = v_snapshot(ctx)
                let mut ci = 0
                while ci < snap0.len() && ci < snap_arm.len() {
                    if snap0[ci] == S_LIVE && snap_arm[ci] != S_LIVE {
                        v_report(ctx, "rc-imbalance", true,
                            "catch arm drops/moves enclosing owned binding '${ctx.names[ci]}' — scope-end will double-free (#167 class)", arm.span)
                    }
                    ci = ci + 1
                }
            }
            v_restore(ctx, snap_body)
            if v_type_excluded(ty, ctx.externs) { CLS_EXCLUDED } else { CLS_OPAQUE }
        },

        HExpr::HandleExpr { body, handlers, ty, .. } => {
            let snap0 = v_snapshot(ctx)
            v_cf_branch(body, mode, ctx)
            let snap_body = v_snapshot(ctx)
            for h in handlers {
                v_restore(ctx, snap0)
                v_handler_scope(h, ctx)
            }
            v_restore(ctx, snap_body)
            if v_type_excluded(ty, ctx.externs) { CLS_EXCLUDED } else { CLS_OPAQUE }
        },

        HExpr::EffectOp { args, ty, .. } => {
            // Args are borrow-passed to the handler closure; fresh-owned args
            // are materialised by ANF (Stage 2 D round) → bare owned arg = gap.
            for a in args { v_borrow(a, "", ctx) }
            if v_type_excluded(ty, ctx.externs) { CLS_EXCLUDED } else { CLS_OPAQUE }
        },

        // B-113: return in expression position (match arm).
        // The return value is consumed (escaped to the caller), and the path
        // diverges — same accounting as HStmt::Return in v_stmt.
        HExpr::ReturnExpr { value, span, .. } => {
            match value {
                some(v) => { let _ = v_consume(v, ctx) },
                none => {},
            }
            // #187: check enclosing owned bindings are dropped before return
            // (mirrors HStmt::Return logic in v_stmt).
            let mut i = 0
            while i < ctx.names.len() {
                if ctx.kinds[i] == K_OWNED && ctx.states[i] == S_LIVE {
                    v_report(ctx, "leak-return", true,
                        "owned binding '${ctx.names[i]}' is live (not dropped) at this return", span)
                }
                i = i + 1
            }
            CLS_EXCLUDED
        },

        // B-125: unsafe block — transparent wrapper, verify the body
        HExpr::UnsafeBlock { body, ty, .. } => {
            v_cf_branch(body, mode, ctx)
            if v_type_excluded(ty, ctx.externs) { CLS_EXCLUDED } else { CLS_OPAQUE }
        },
    }
}

fn v_cls_of_fresh(ty: Type, externs: Set<Str>) -> Int {
    if v_type_excluded(ty, externs) {
        CLS_EXCLUDED
    } else {
        // D1 rule ① (audit #139): a production whose type transitively CONTAINS
        // an extern handle (LLVMValueRef?, List<LLVMTypeRef>, LlvmCtx, …) is
        // excluded from materialisation and droppability — it leaks by rule
        // (its deep drop would reach the foreign pointer).  Outside the account.
        if type_contains_extern_handle(ty, externs) { CLS_EXCLUDED } else { CLS_OWNED }
    }
}

// (v_andor retired 2026-06-13 — B-104 D7: `&&`/`||` are lowered to IfExpr by
//  andor_lower at checker end and never reach post-RC HIR; the x-andor
//  exemption class retired with it.)

// Identifier read/move.
fn v_ident(
    name: Str, def_id: Int?, ty: Type, span: Span,
    mode: Int, mut ctx: VCtx
) -> Int {
    let name_index = v_lookup_name(ctx, name)
    let idx = match def_id {
        some(id) => {
            let exact_index = v_lookup(ctx, id)
            if exact_index >= 0 && ctx.names[exact_index] != name {
                panic("RC verifier DefId ${id} names '${ctx.names[exact_index]}', not '${name}'")
            }
            if exact_index < 0 && name_index >= 0 {
                panic("RC verifier local reference '${name}' has mismatched DefId ${id}")
            }
            exact_index
        },
        none => {
            if name_index >= 0 {
                panic("RC verifier local reference '${name}' has no exact DefId")
            }
            0 - 1
        }
    }
    // An exact owned producer (slot read/take or Clone<TypeVar>) can bind an
    // unnamed TypeVar.  Binding provenance is stronger than the generic
    // type-level exclusion, so account K_OWNED before applying that guard.
    if idx < 0 || ctx.kinds[idx] != K_OWNED {
        if v_type_excluded(ty, ctx.externs) {
            return CLS_EXCLUDED
        }
    }
    if idx < 0 {
        // Module-level fn / const / enum-variant reference: reads borrow; the
        // pass Clone-wraps owner-bearing escapes, so a bare consumed global is
        // flagged by v_consume via the BORROW class.
        return CLS_BORROW
    }
    if ctx.kinds[idx] == K_OWNED {
        if ctx.states[idx] == S_DROPPED {
            v_report(ctx, "uaf-use-after-drop", true,
                "read of '${name}' after its Drop", span)
            CLS_BORROW
        } else if ctx.states[idx] == S_MOVED {
            v_report(ctx, "uaf-use-after-drop", true,
                "read of '${name}' after its value was moved out", span)
            CLS_BORROW
        } else {
            if mode == M_CONSUMED {
                // Pass-synthesised move (`__rc_scope_N` hoist / W4 tmp): the
                // binding's value transfers to the consumer.
                ctx.states.set(idx, S_MOVED)
                CLS_OWNED
            } else {
                CLS_BORROW
            }
        }
    } else {
        if ctx.kinds[idx] == K_NONOWNED && mode == M_CONSUMED {
            // Verbatim move of a non-owned local (And/Or hoist etc.): content
            // ownership is unknown; the leak was reported at its binding.
            ctx.states.set(idx, S_MOVED)
            CLS_OPAQUE
        } else {
            CLS_BORROW
        }
    }
}

// A control-flow branch / arm body walked in the parent's mode; in a
// non-consuming position an owned branch value has no consumer — the
// documented x-cf-value class (discarded / borrowed control-flow values).
fn v_cf_branch(body: HExpr, mode: Int, mut ctx: VCtx) -> (Int, Bool) {
    let r = v_branch(body, mode, ctx)
    if mode == M_BORROWED && r.0 == CLS_OWNED && r.1 == false {
        v_report(ctx, "x-cf-value", false,
            "control-flow branch yields an owned value in a non-consuming position (documented leak)", hexpr_span(body))
    }
    r
}

fn v_branch(body: HExpr, mode: Int, mut ctx: VCtx) -> (Int, Bool) {
    match body {
        HExpr::Block { .. } => v_block(body, mode, ctx),
        _ => {
            let cls = if mode == M_CONSUMED { v_consume(body, ctx) } else { v_expr(body, M_BORROWED, ctx) }
            ((cls, expr_diverges(body)))
        },
    }
}

// Combined class of a control-flow expression from its branch results.
fn v_cf_class(ty: Type, results: List<(Int, Bool)>, mode: Int, ctx: VCtx) -> Int {
    if v_type_excluded(ty, ctx.externs) {
        return CLS_EXCLUDED
    }
    if mode == M_BORROWED {
        // Owned branch values were reported per-branch (x-cf-value); the
        // expression's value in a read position is at most a borrow.
        return CLS_OPAQUE
    }
    let mut all_owned = true
    let mut any = false
    for r in results {
        if r.1 == false {
            any = true
            if r.0 != CLS_OWNED && r.0 != CLS_EXCLUDED { all_owned = false }
        }
    }
    if any && all_owned { CLS_OWNED } else { CLS_OPAQUE }
}

// Two-way branch state merge (if/else, if-let).
fn v_merge_two(mut ctx: VCtx, t_div: Bool, snap_t: List<Int>, e_div: Bool, snap_e: List<Int>, snap0: List<Int>, span: Span) {
    if t_div && e_div {
        v_restore(ctx, snap0)
    } else if t_div {
        v_restore(ctx, snap_e)
    } else if e_div {
        v_restore(ctx, snap_t)
    } else {
        if v_states_equal(snap_t, snap_e, snap0.len()) == false {
            v_report(ctx, "rc-imbalance", true,
                "branches leave enclosing RC binding states imbalanced (#134 class)", span)
        }
        v_restore(ctx, snap_t)
    }
}

fn v_handler_scope(h: HEffectHandler, mut ctx: VCtx) {
    // Handler arms become closures at codegen; bodies are their own function
    // scope with borrowed op params (and the resume binding, when present).
    let mut hctx = v_new_ctx(ctx.boxed, ctx.externs, ctx.findings, "${ctx.fn_name}/handler ${h.effect_name}.${h.op_name}")
    v_push_frame(hctx)
    let mut capture_index = 0
    while capture_index < ctx.names.len() {
        v_bind(hctx, ctx.names[capture_index], ctx.def_ids[capture_index],
            K_CAPTURE, ctx.spans[capture_index])
        capture_index = capture_index + 1
    }
    for p in h.params {
        let def_id = v_required_def_id(
            p.def_id, "handler parameter '${p.name}'")
        v_bind(hctx, p.name, def_id, K_BORROW, synthetic_vspan())
    }
    match h.resume_binding {
        some(binding) => v_bind(hctx, binding.name, binding.def_id,
            K_BORROW, synthetic_vspan()),
        none => {},
    }
    match h.body {
        HExpr::Block { .. } => {
            v_block(h.body, M_CONSUMED, hctx)
        },
        _ => {
            v_consume(h.body, hctx)
            ((0, false))
        },
    }
    v_pop_frame(hctx)
}

// ============================================================
// Blocks and statements
// ============================================================

fn v_block(block: HExpr, mode: Int, mut ctx: VCtx) -> (Int, Bool) {
    match block {
        HExpr::Block { stmts, tail, .. } => {
            v_push_frame(ctx)
            let mut diverged = false
            for s in stmts {
                if diverged == false {
                    if v_stmt(s, ctx) { diverged = true }
                }
            }
            let mut cls = CLS_EXCLUDED
            if diverged == false {
                match tail {
                    some(t) => {
                        cls = v_block_tail(t, mode, ctx)
                        if expr_diverges(t) { diverged = true }
                    },
                    none => {},
                }
            }
            if diverged == false {
                v_check_frame_leaks(ctx)
            }
            v_pop_frame(ctx)
            ((cls, diverged))
        },
        _ => {
            let cls = if mode == M_CONSUMED { v_consume(block, ctx) } else { v_expr(block, M_BORROWED, ctx) }
            ((cls, expr_diverges(block)))
        },
    }
}

// A block tail.  POST-RC SHAPE: a dropping block's tail was hoisted into
// `let __rc_scope_N = <escape-processed tail>` and the syntactic tail is a
// bare Ident of THIS block's binding — that read is a MOVE-OUT (the value
// transfers to the parent) regardless of the parent's mode (the tail-escape
// invariant made it owned).  Any other tail follows the parent's mode.
fn v_block_tail(t: HExpr, mode: Int, mut ctx: VCtx) -> Int {
    let base = v_frame_base(ctx)
    match t {
        HExpr::Ident { name, def_id, .. } => {
            let idx = match def_id {
                some(id) => {
                    let exact_index = v_lookup(ctx, id)
                    if exact_index >= 0 && ctx.names[exact_index] != name {
                        panic("RC verifier tail DefId ${id} names '${ctx.names[exact_index]}', not '${name}'")
                    }
                    if exact_index < 0 && v_lookup_name(ctx, name) >= 0 {
                        panic("RC verifier tail '${name}' has mismatched DefId ${id}")
                    }
                    exact_index
                },
                none => {
                    if v_lookup_name(ctx, name) >= 0 {
                        panic("RC verifier tail local '${name}' has no exact DefId")
                    }
                    0 - 1
                }
            }
            if idx >= base && idx >= 0 {
                if ctx.kinds[idx] == K_OWNED && ctx.states[idx] == S_LIVE {
                    ctx.states.set(idx, S_MOVED)
                    CLS_OWNED
                } else {
                    if ctx.kinds[idx] == K_NONOWNED && ctx.states[idx] == S_LIVE {
                        ctx.states.set(idx, S_MOVED)
                        CLS_OPAQUE
                    } else {
                        v_expr(t, M_BORROWED, ctx)
                    }
                }
            } else {
                if mode == M_CONSUMED { v_consume(t, ctx) } else { v_expr(t, M_BORROWED, ctx) }
            }
        },
        _ => {
            if mode == M_CONSUMED { v_consume(t, ctx) } else { v_expr(t, mode, ctx) }
        },
    }
}

fn v_check_frame_leaks(mut ctx: VCtx) {
    let base = v_frame_base(ctx)
    let mut i = base
    while i < ctx.names.len() {
        if ctx.kinds[i] == K_OWNED && ctx.states[i] == S_LIVE {
            v_report(ctx, "leak-binding", true,
                "owned binding '${ctx.names[i]}' is never consumed (no drop/move) on the fall-through path", ctx.spans[i])
        }
        i = i + 1
    }
}

fn v_stmt(stmt: HStmt, mut ctx: VCtx) -> Bool {
    match stmt {
        HStmt::Let { name, def_id, init, span, .. } => {
            v_let_like(name, def_id, init, span, ctx)
            false
        },
        HStmt::Var { name, def_id, init, span, .. } => {
            v_let_like(name, def_id, init, span, ctx)
            false
        },
        HStmt::Assign { target, value, span } => {
            v_assign(target, value, span, ctx)
            false
        },
        HStmt::ExprStmt { expr, .. } => {
            // Discarded statement value: ANF materialises fresh non-control-flow
            // values (the binding is scope-end-dropped); control-flow report
            // their owned tails as x-cf-value internally.
            v_borrow(expr, "", ctx)
            stmt_diverges(stmt)
        },
        HStmt::Return { value, span } => {
            match value {
                some(v) => { v_consume(v, ctx) },
                none => CLS_EXCLUDED,
            }
            // The pass emits drops for the FULL visible owned set before the
            // Return — every owned binding still LIVE here was missed.
            let mut i = 0
            while i < ctx.names.len() {
                if ctx.kinds[i] == K_OWNED && ctx.states[i] == S_LIVE {
                    v_report(ctx, "leak-return", true,
                        "owned binding '${ctx.names[i]}' is live (not dropped) at this return", span)
                }
                i = i + 1
            }
            true
        },
        HStmt::While { condition, body, span } => {
            v_cond(condition, ctx)
            ctx.loop_bases.push(ctx.names.len())
            let snap0 = v_snapshot(ctx)
            v_block(body, M_BORROWED, ctx)
            // A loop body must be state-neutral for enclosing bindings (it may
            // run zero or N times); W4 drop+revive pairs are net-identity.
            let cur = v_snapshot(ctx)
            if v_states_equal(snap0, cur, snap0.len()) == false {
                v_report(ctx, "rc-imbalance", true,
                    "loop body leaves enclosing RC binding states changed", span)
            }
            v_restore(ctx, snap0)
            ctx.loop_bases.pop()
            false
        },
        HStmt::ForIn { binding, def_id, destructure,
                       iterable, body, span, .. } => {
            match iterable {
                // A literal RangeExpr iterable is lowered by emit_for_in_range_direct
                // (a direct counting loop that drops its own counter/bound boxes —
                // B-104b); its owned value is accepted inline.
                HExpr::RangeExpr { .. } => { v_expr(iterable, M_BORROWED, ctx) },
                _ => { v_borrow(iterable, "", ctx) },
            }
            ctx.loop_bases.push(ctx.names.len())
            let snap0 = v_snapshot(ctx)
            v_push_frame(ctx)
            if binding != "_" {
                let binding_id = v_required_def_id(
                    def_id, "for binding '${binding}'")
                v_bind(ctx, binding, binding_id, K_BORROW, span)
            }
            match destructure {
                some(ds) => {
                    for d in ds {
                        if d.name != "_" {
                            let destructure_id = v_required_def_id(d.def_id,
                                "for destructure '${d.name}'")
                            v_bind(ctx, d.name, destructure_id,
                                K_BORROW, span)
                        }
                    }
                },
                none => {},
            }
            v_block(body, M_BORROWED, ctx)
            v_pop_frame(ctx)
            let cur = v_snapshot(ctx)
            if v_states_equal(snap0, cur, snap0.len()) == false {
                v_report(ctx, "rc-imbalance", true,
                    "loop body leaves enclosing RC binding states changed", span)
            }
            v_restore(ctx, snap0)
            ctx.loop_bases.pop()
            false
        },
        HStmt::Break { span } => {
            v_check_loop_exit(ctx, span, "break")
            true
        },
        HStmt::Continue { span } => {
            v_check_loop_exit(ctx, span, "continue")
            true
        },
        HStmt::LetDestructure { bindings, init, span, .. } => {
            // The destructure PROJECTS borrows out of the init (no ownership
            // taken); a fresh init was materialised by ANF (Stage 2 C2).
            v_borrow(init, "", ctx)
            for b in bindings {
                if b.name != "_" {
                    let binding_id = v_required_def_id(
                        b.def_id, "destructure '${b.name}'")
                    v_bind(ctx, b.name, binding_id, K_BORROW, span)
                }
            }
            false
        },
        HStmt::IfLet { bindings, expr, then_block, else_block, span, .. } => {
            v_borrow(expr, "", ctx)
            let snap0 = v_snapshot(ctx)
            v_push_frame(ctx)
            for binding in bindings {
                v_bind(ctx, binding.name, binding.def_id, K_BORROW, span)
            }
            let rt = v_block(then_block, M_BORROWED, ctx)
            v_pop_frame(ctx)
            let snap_t = v_snapshot(ctx)
            v_restore(ctx, snap0)
            let re = match else_block {
                some(eb) => v_block(eb, M_BORROWED, ctx),
                none => ((CLS_EXCLUDED, false)),
            }
            let snap_e = v_snapshot(ctx)
            v_merge_two(ctx, rt.1, snap_t, re.1, snap_e, snap0, span)
            rt.1 && re.1
        },
        HStmt::Drop { name, def_id, place_target, span, .. } => {
            match place_target {
                some(target) => { let _ = v_borrow(target, "", ctx) },
                none => { v_drop(name, def_id, span, ctx) }
            }
            false
        }
    }
}

fn v_let_like(
    name: Str, def_id: Int?, init: HExpr, span: Span, mut ctx: VCtx
) {
    let cls = v_consume(init, ctx)
    if rc_name_skippable(name) {
        if cls == CLS_OWNED {
            v_report(ctx, "x-discard", false,
                "`_` discards an owned value without a drop (documented leak)", span)
        }
        return
    }
    let exact_def_id = v_required_def_id(
        def_id, "local binding '${name}'")
    let bind_span = if span.file == "<perceus>" { hexpr_span(init) } else { span }
    if v_droppable_init(init, ctx.externs) {
        v_bind(ctx, name, exact_def_id, K_OWNED, bind_span)
    } else {
        v_bind(ctx, name, exact_def_id, K_NONOWNED, bind_span)
        // D1 rule ①: a contains-extern binding is non-droppable BY RULE (its
        // deep drop would reach the foreign handle) — documented, not a finding.
        if type_contains_extern_handle(hexpr_type(init), ctx.externs) {
            return
        }
        // Document the non-owned content when it is (or may be) owned:
        if cls == CLS_OWNED {
            v_report(ctx, "x-cf-value", false,
                "owned value bound by a non-droppable binding '${name}' (documented leak)", bind_span)
        } else {
            if cls == CLS_OPAQUE {
                v_report(ctx, v_opaque_exempt_class(init), false,
                    "possibly-owned value bound by non-droppable binding '${name}' (documented leak class)", bind_span)
            }
        }
    }
}

fn v_opaque_exempt_class(init: HExpr) -> Str {
    match init {
        // (BinOp is never OPAQUE post-D7 — `&&`/`||` were the only opaque
        //  BinOps and andor_lower retired them; falls to the catch-all.)
        HExpr::EffectOp { .. } => "x-effect-value",
        HExpr::TryCatch { .. } => "x-effect-value",
        HExpr::HandleExpr { .. } => "x-effect-value",
        HExpr::IfExpr { .. } => "x-cf-value",
        HExpr::MatchExpr { .. } => "x-cf-value",
        HExpr::Block { .. } => "x-cf-value",
        HExpr::Ident { .. } => "x-cf-value",
        _ => "x-cf-value",
    }
}

fn v_assign(target: HExpr, value: HExpr, span: Span, mut ctx: VCtx) {
    match target {
        HExpr::Ident { name, def_id, ty, .. } => {
            v_consume(value, ctx)
            let exact_def_id = v_required_def_id(
                def_id, "assignment '${name}'")
            let idx = v_lookup(ctx, exact_def_id)
            if idx >= 0 && ctx.names[idx] != name {
                panic("RC verifier assignment DefId ${exact_def_id} names '${ctx.names[idx]}', not '${name}'")
            }
            if idx < 0 && v_lookup_name(ctx, name) >= 0 {
                panic("RC verifier assignment '${name}' has mismatched DefId ${exact_def_id}")
            }
            if idx < 0 {
                return
            }
            if ctx.kinds[idx] == K_BORROW {
                v_report(ctx, "x-overwrite-param", false,
                    "assignment to borrowed binding '${name}' overwrites a value owned elsewhere (documented)", span)
                return
            }
            if ctx.kinds[idx] == K_CAPTURE {
                // The nested callable borrows the outer slot. The outer frame
                // remains the ownership authority; do not re-arm or own it here.
                return
            }
            if ctx.states[idx] == S_LIVE && ctx.kinds[idx] == K_OWNED {
                // Old value overwritten while live.
                let boxed_var = ctx.boxed.contains(exact_def_id)
                if v_type_excluded(ty, ctx.externs) || type_contains_extern_handle(ty, ctx.externs) {
                    // outside the account
                } else if boxed_var {
                    v_report(ctx, "x-overwrite-boxed", false,
                        "write to auto-boxed mut cell '${name}' leaks the old cell value (B-091, documented)", span)
                } else if is_scalar_type(ty) {
                    // W4 guarantees [materialise RHS, Drop old, Assign] for plain
                    // scalar vars — a live-state scalar overwrite means the W4
                    // drop is missing (pass regression).
                    v_report(ctx, "leak-scalar-reassign", true,
                        "scalar mut-var '${name}' reassigned without the W4 old-value drop", span)
                } else {
                    v_report(ctx, "x-overwrite-var", false,
                        "non-scalar mut-var '${name}' reassignment leaks the old value (W4 scalar-only, documented)", span)
                }
            }
            // The write re-arms the slot (W4 drop→assign revive included).
            ctx.states.set(idx, S_LIVE)
        },
        HExpr::FieldAccess { receiver, field, ty, .. } => {
            v_borrow(receiver, "", ctx)
            v_consume(value, ctx)
            if v_type_excluded(ty, ctx.externs) == false && type_contains_extern_handle(ty, ctx.externs) == false {
                v_report(ctx, "x-overwrite-field", false,
                    "field '${field}' overwrite does not drop the old value (codegen field-store convention; B-109 ① class)", span)
            }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            // list[i] = v / map[k] = v lower to the runtime set/insert family,
            // which store-then-drop the old slot value (D1 rule ④) — accounted.
            v_borrow(receiver, "", ctx)
            v_borrow(index, "", ctx)
            let _ = v_consume(value, ctx)
        },
        _ => {
            let _ = v_consume(value, ctx)
        },
    }
}

fn v_drop(name: Str, def_id: Int, span: Span, mut ctx: VCtx) {
    let idx = v_lookup(ctx, def_id)
    if idx >= 0 && ctx.names[idx] != name {
        panic("RC verifier Drop DefId ${def_id} names '${ctx.names[idx]}', not '${name}'")
    }
    if idx < 0 && v_lookup_name(ctx, name) >= 0 {
        panic("RC verifier Drop '${name}' has mismatched DefId ${def_id}")
    }
    if idx < 0 {
        v_report(ctx, "uaf-drop-unknown", true,
            "Drop of '${name}' which is not in scope", span)
        return
    }
    if ctx.kinds[idx] == K_BORROW || ctx.kinds[idx] == K_CAPTURE {
        v_report(ctx, "uaf-drop-borrow", true,
            "Drop of borrowed binding '${name}' (param/pattern/for-in projection) — frees a reference owned elsewhere", span)
        return
    }
    if ctx.kinds[idx] == K_NONOWNED {
        v_report(ctx, "uaf-drop-borrow", true,
            "Drop of non-droppable binding '${name}' (And-Or/effect/excluded init — possibly a borrow)", span)
        return
    }
    if ctx.states[idx] == S_DROPPED {
        v_report(ctx, "uaf-double-drop", true,
            "second Drop of '${name}' on the same path", span)
        return
    }
    if ctx.states[idx] == S_MOVED {
        v_report(ctx, "uaf-double-drop", true,
            "Drop of '${name}' after its value was moved out", span)
        return
    }
    ctx.states.set(idx, S_DROPPED)
}

// Break/Continue exit the innermost loop without running the loop body's
// block-end drops — every owned binding declared inside the loop and still
// live leaks (once per exit for break, once per iteration for continue).
fn v_check_loop_exit(mut ctx: VCtx, span: Span, what: Str) {
    let n = ctx.loop_bases.len()
    if n == 0 {
        return
    }
    let base = ctx.loop_bases[n - 1]
    let mut i = base
    while i < ctx.names.len() {
        if ctx.kinds[i] == K_OWNED && ctx.states[i] == S_LIVE {
            v_report(ctx, "leak-loop-exit", true,
                "owned binding '${ctx.names[i]}' is live (not dropped) at this ${what}", span)
        }
        i = i + 1
    }
}

fn v_list_has_int(xs: List<Int>, x: Int) -> Bool {
    let mut found = false
    for v in xs { if v == x { found = true } }
    found
}
