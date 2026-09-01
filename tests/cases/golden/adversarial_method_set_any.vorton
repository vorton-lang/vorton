// B-100 Phase 1.3 adversarial: Set.any — no method_to_runtime mapping,
// uses user-impl lookup (no method_to_runtime fast path).
fn main() {
    let mut s: Set<Str> = set_new()
    s.insert("hello")
    s.insert("world")
    let has_long = s.any(fn(v) { v.len() > 4 })
    print("any_long=${has_long}")
    let has_short = s.any(fn(v) { v.len() < 3 })
    print("any_short=${has_short}")
}
