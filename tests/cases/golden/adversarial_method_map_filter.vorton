// B-100 Phase 1.3 adversarial: Map.filter — no method_to_runtime mapping,
// uses user-impl lookup (no method_to_runtime fast path).
fn main() {
    let mut m: Map<Str, Int> = map_new()
    m.insert("a", 1)
    m.insert("b", 2)
    m.insert("c", 3)
    let filtered = m.filter(fn(k, v) { v > 1 })
    print("filter_len=${filtered.len()}")
    print("filter_has_a=${filtered.contains_key("a")}")
    print("filter_has_b=${filtered.contains_key("b")}")
    print("filter_has_c=${filtered.contains_key("c")}")
}
