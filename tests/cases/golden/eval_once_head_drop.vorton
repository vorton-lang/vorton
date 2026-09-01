// B-104 D1 Stage 2 regression: evaluated-once statement HEADS materialise +
// scope-end-drop their fresh-owned value.
//   * ForIn ITERABLE: `for e in m.entries()` / `for x in xs.filter(p)` — the
//     fresh container was read by the loop and never dropped.  Loop bindings
//     borrow the materialised __anf's elements; element escapes Clone-wrap;
//     __anf drops after the loop.  A wrong early drop → elements freed while
//     the loop reads them → native crash / divergence vs the golden .expected.
//   * RangeExpr iterable EXEMPT (stays inline): the direct counting-loop
//     lowering (emit_for_in_range_direct) + its B-104b drops must keep seeing
//     the literal RangeExpr form.
//   * IfLet SCRUTINEE: `if let some(v) = m.get(k)` — W2-identical balance
//     (pattern bindings project borrows; escapes Clone-wrap; __anf drops at
//     scope end).  Both arms + escape-into-outer exercised.

fn make_list() -> List<Int> {
    [3, 1, 4, 1, 5]
}

fn main() {
    // ForIn over a fresh Call iterable (the map-iteration pattern).
    let mut m: Map<Str, Int> = map_new()
    m.insert("a", 1)
    m.insert("b", 2)
    m.insert("c", 3)
    let mut sum = 0
    let mut keys = ""
    for e in m.entries() {
        keys = "${keys}${e.0}"
        sum = sum + e.1
    }
    print("${keys}:${sum}")

    // ForIn over a fresh HOF-chain iterable; element escapes into outer list.
    // (join is List<Str>-only on native — List<Int>.join is audit #148.)
    let mut kept: List<Str> = []
    for x in make_list().filter(fn(v) { v > 1 }) {
        kept.push("${x}")
    }
    print(kept.join(","))

    // return/break inside the body: owned set (incl. the materialised
    // iterable) is dropped on the return path.
    let mut firstbig = 0
    for x in make_list() {
        if x > 3 {
            firstbig = x
            break
        }
    }
    print("firstbig=${firstbig}")

    // RangeExpr iterable: exempt path, still the direct counting loop.
    let mut rsum = 0
    for i in 0..4 {
        rsum = rsum + i
    }
    print("rsum=${rsum}")

    // IfLet with fresh scrutinee: both arms; binding escapes to outer.
    let mut found = ""
    if let some(v) = m.get("b") {
        found = "b=${v}"
    } else {
        found = "none"
    }
    print(found)
    if let some(v) = m.get("zzz") {
        print("bad ${v}")
    } else {
        print("miss")
    }

    // IfLet over a fresh Option whose payload escapes (Clone-wrap balance).
    let mut grabbed: List<Int> = []
    if let some(first) = make_list().first() {
        grabbed.push(first)
    }
    print("grabbed=${grabbed.len()}:${grabbed[0]}")
}
