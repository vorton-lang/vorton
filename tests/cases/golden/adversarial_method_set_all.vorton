// B-100 Phase 1.3 adversarial: Set.all — no method_to_runtime mapping,
// uses user-impl lookup (no method_to_runtime fast path).
fn main() {
    let mut s: Set<Int> = set_new()
    s.insert(2)
    s.insert(4)
    s.insert(6)
    let all_even = s.all(fn(v) { v % 2 == 0 })
    print("all_even=${all_even}")
    s.insert(3)
    let still_even = s.all(fn(v) { v % 2 == 0 })
    print("still_even=${still_even}")
}
