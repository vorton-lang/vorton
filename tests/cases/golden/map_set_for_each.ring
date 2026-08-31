// B-129 Map/Set HOF llvm_diff coverage.
// Pure-Ring Map HOF methods iterate occupied slots and obtain owned callback
// arguments through ring_slot_read; pure-Ring Set HOFs forward to that Map.
// Map output below pins fixed-input traversal; Set assertions stay
// order-independent because Set iteration order is unspecified. Callbacks
// include heap-allocated intermediates to exercise the #152 HOF drop fix.

fn main() {
    // ── Map<Str, Str> fold ──
    let mut m: Map<Str, Str> = map_new()
    m.insert("a", "1")
    m.insert("b", "2")
    m.insert("c", "3")

    // fold with string accumulator (heap alloc per iteration)
    let joined = m.fold("", fn(acc, k, v) { "${acc}${k}=${v};" })
    print("map_fold=${joined}")

    // ── Map<Str, Str> filter ──
    let filtered = m.filter(fn(k, v) { k != "b" })
    print("map_filter_len=${filtered.len()}")
    print("map_filter_has_a=${filtered.contains_key("a")}")
    print("map_filter_has_b=${filtered.contains_key("b")}")
    print("map_filter_has_c=${filtered.contains_key("c")}")

    // ── Map<Str, Str> any ──
    let has_c = m.any(fn(k, v) { k == "c" })
    print("map_any_c=${has_c}")
    let has_z = m.any(fn(k, v) { k == "z" })
    print("map_any_z=${has_z}")

    // ── Map<Str, Str> map_values ──
    let upper = m.map_values(fn(v) { "${v}${v}" })
    let uv = upper.fold("", fn(acc, k, v) { "${acc}${k}:${v};" })
    print("map_values=${uv}")

    // ── Map<Int, Str> fold ──
    let mut mi: Map<Int, Str> = map_new()
    mi.insert(10, "x")
    mi.insert(20, "y")
    mi.insert(30, "z")
    let mi_joined = mi.fold("", fn(acc, k, v) { "${acc}${k}-${v};" })
    print("map_int_fold=${mi_joined}")

    // ── Set<Str> fold ──
    let mut s: Set<Str> = set_new()
    s.insert("x")
    s.insert("y")
    s.insert("z")
    let s_total_len = s.fold(0, fn(acc, v) { acc + v.len() })
    print("set_fold_total_len=${s_total_len}")

    // ── Set<Str> filter ──
    let sf = s.filter(fn(v) { v != "y" })
    print("set_filter_len=${sf.len()}")

    // ── Set<Str> any / all ──
    let s_any = s.any(fn(v) { v == "z" })
    print("set_any_z=${s_any}")
    let s_all = s.all(fn(v) { v.len() == 1 })
    print("set_all_len1=${s_all}")

    // ── Set<Int> fold ──
    let mut si: Set<Int> = set_new()
    si.insert(3)
    si.insert(1)
    si.insert(2)
    let si_sum = si.fold(0, fn(acc, v) { acc + v })
    print("set_int_sum=${si_sum}")

    // ── HOF drop stress: callback with heap-allocated intermediates ──
    let mut m2: Map<Str, Str> = map_new()
    m2.insert("k1", "hello")
    m2.insert("k2", "world")
    let concat = m2.fold("", fn(acc, k, v) {
        // intermediate string allocs that must be dropped
        let tmp = "${k}=${v}"
        "${acc}[${tmp}]"
    })
    print("drop_stress=${concat}")

    print("done")
}
