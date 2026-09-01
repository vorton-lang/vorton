// B-100 Phase 1.3 adversarial: Map.any — no method_to_runtime mapping,
// uses user-impl lookup (no method_to_runtime fast path).
fn main() {
    let mut m: Map<Str, Int> = map_new()
    m.insert("a", 1)
    m.insert("b", 2)
    m.insert("c", 3)
    let has_big = m.any(fn(k, v) { v > 2 })
    print("any_big=${has_big}")
    let has_huge = m.any(fn(k, v) { v > 100 })
    print("any_huge=${has_huge}")
}
