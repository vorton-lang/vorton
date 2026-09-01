// B-104 D1 Stage 2 regression: a DISCARDED statement-position value (ExprStmt)
// is materialised + scope-end-dropped.
//
// What this pins:
//   * non-Unit fresh results discarded for side effects (`xs.pop()`,
//     `xs.get(i)`, a constructor, an interp string) previously leaked (no
//     owner); now they get a __anf binding + scope-end drop.  A wrong drop of
//     a still-live value (e.g. treating a borrow-returning result as fresh)
//     would free shared state → native crash / divergence; the golden .expected
//     pins all outputs and the post-discard re-reads prove nothing live was freed.
//   * Unit-typed calls (print/push/insert/remove, rule 2) stay
//     un-materialised — their ABI receiver-return must never be dropped.
//   * mutation-then-discard ordering: the discarded op's side effect must be
//     observable afterwards (pop really popped, container intact).

struct Box { v: Int }

fn make_box(v: Int) -> Box {
    Box { v: v }
}

// audit #149 guard shape: an UNANNOTATED fn's return type is over-generalised
// to a free TypeVar (checker hole), and its body tail is a receiver-returning
// Unit builtin — at the LLVM ABI the call hands back the LIVE receiver,
// un-dup'd.  The unknown-ownership (TypeVar) guard must keep such results
// un-materialised and un-droppable in EVERY position, or the caller's
// container double-frees (ASan-proven pre-guard).
fn tail_mutate(mut xs: List<Int>) { xs.push(42) }

fn main() {
    let mut xs = [1, 2, 3, 4]

    // Discarded Option result: pop's popped value had no owner before.
    xs.pop()
    print("after pop: ${xs.len()}")

    // Discarded fresh struct / fresh string results.
    make_box(7)
    "tmp${1 + 1}"
    print("alive")

    // Discarded borrow-returning result: NOT materialised (stays a borrow).
    let opt: Int? = some(5)
    opt.unwrap_or(0)
    print("opt=${opt.unwrap_or(-1)}")

    // Unit mutators in statement position: receiver-return excluded by rule 2;
    // container fully usable afterwards.
    xs.push(9)
    xs.push(10)
    let mut m: Map<Str, Int> = map_new()
    m.insert("a", 1)
    m.remove("a")
    m.insert("b", 2)
    print("xs=${xs.len()} m=${m.len()}")

    // Discarded results inside a loop body (per-iteration block scope).
    let mut i = 0
    while i < 3 {
        xs.get(i)
        i = i + 1
    }

    // audit #149 guard: unannotated-fn (TypeVar-typed) results must not be
    // dropped — statement position AND let-binding position; the receiver
    // must stay alive and mutated afterwards.
    let mut ys = [1]
    tail_mutate(ys)
    let r = tail_mutate(ys)
    print("ys=${ys.len()} last=${ys[2]}")
    print("done")
}
