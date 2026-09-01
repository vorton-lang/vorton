// B-100 Phase 1.3 adversarial: Set.filter — no method_to_runtime mapping,
// uses user-impl lookup (no method_to_runtime fast path).
fn main() {
    let mut s: Set<Str> = set_new()
    s.insert("apple")
    s.insert("banana")
    s.insert("cherry")
    let short = s.filter(fn(v) { v.len() < 6 })
    print("filter_len=${short.len()}")
    // Check specific membership
    let items = short.to_list()
    for item in items {
        print("kept=${item}")
    }
}
