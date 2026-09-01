// B-100 P1.3 R3 regression: Map/Set HOF chaining and complex fold.
//
// Round 2 fixed Map/Set runtime implementations (filter, any, all, fold,
// map_values). This test pushes the fix with:
//   * Map.filter -> map_values chain
//   * Set.filter -> all chain
//   * Map.fold building a List (non-trivial accumulator)
//   * Map.fold building a Str (complex concatenation)
//   * Empty Map/Set fold/filter/any/all
//
// All outputs are deterministic due to sorted iteration order.

fn main() {
    // ── Map.filter -> map_values chain ──
    let mut m: Map<Str, Int> = map_new()
    m.insert("a", 1)
    m.insert("b", 2)
    m.insert("c", 3)
    m.insert("d", 4)

    // Filter values > 1, then double remaining
    let chained = m.filter(fn(k, v) { v > 1 }).map_values(fn(v) { v * 2 })
    let result = chained.fold("", fn(acc, k, v) { "${acc}${k}:${v};" })
    print("T1: ${result}")

    // ── Map.filter -> filter chain ──
    let double_filtered = m.filter(fn(k, v) { v > 1 }).filter(fn(k, v) { v < 4 })
    let df_result = double_filtered.fold("", fn(acc, k, v) { "${acc}${k}=${v};" })
    print("T2: ${df_result}")

    // ── Set.filter -> all chain ──
    let mut s: Set<Int> = set_new()
    s.insert(2)
    s.insert(4)
    s.insert(6)
    s.insert(7)
    s.insert(8)

    // Filter to even, then check if all > 1
    let evens = s.filter(fn(v) { v % 2 == 0 })
    let all_gt1 = evens.all(fn(v) { v > 1 })
    print("T3a: ${all_gt1}")
    print("T3b: evens_len=${evens.len()}")

    // ── Set.filter -> any chain ──
    let big = evens.filter(fn(v) { v > 5 })
    let has_eight = big.any(fn(v) { v == 8 })
    print("T4a: ${has_eight}")
    let has_ten = big.any(fn(v) { v == 10 })
    print("T4b: ${has_ten}")

    // ── Map.fold building a complex Str (multi-field per entry) ──
    let mut scores: Map<Str, Int> = map_new()
    scores.insert("alice", 95)
    scores.insert("bob", 80)
    scores.insert("carol", 90)

    let entries_str = scores.fold("", fn(acc, k, v) {
        let pass = if v >= 90 { "PASS" } else { "FAIL" }
        "${acc}${k}(${v},${pass});"
    })
    print("T5: ${entries_str}")

    // ── Map.fold building complex Str ──
    let summary = scores.fold("scores:", fn(acc, k, v) {
        "${acc} [${k}=${v}]"
    })
    print("T6: ${summary}")

    // ── Empty Map operations ──
    let empty_m: Map<Str, Int> = map_new()
    let ef = empty_m.filter(fn(k, v) { v > 0 })
    print("T7a: empty_filter_len=${ef.len()}")
    let ea = empty_m.any(fn(k, v) { v > 0 })
    print("T7b: empty_any=${ea}")
    let efold = empty_m.fold("init", fn(acc, k, v) { "${acc}+${k}" })
    print("T7c: empty_fold=${efold}")
    let emv = empty_m.map_values(fn(v) { v * 2 })
    print("T7d: empty_mv_len=${emv.len()}")

    // ── Empty Set operations ──
    let empty_s: Set<Int> = set_new()
    let esf = empty_s.filter(fn(v) { v > 0 })
    print("T8a: empty_set_filter_len=${esf.len()}")
    let esa = empty_s.any(fn(v) { v > 0 })
    print("T8b: empty_set_any=${esa}")
    let esall = empty_s.all(fn(v) { v > 0 })
    print("T8c: empty_set_all=${esall}")
    let esfold = empty_s.fold(0, fn(acc, v) { acc + v })
    print("T8d: empty_set_fold=${esfold}")

    print("adversarial_regress_map_chain_ops: done")
}
