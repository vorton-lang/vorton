// B-100 Phase 1.3 adversarial: Map.map_values — no method_to_runtime mapping,
// uses user-impl lookup (no method_to_runtime fast path).
fn main() {
    let mut m: Map<Str, Int> = map_new()
    m.insert("x", 10)
    m.insert("y", 20)
    let doubled = m.map_values(fn(v) { v * 2 })
    // Verify via entries iteration order (sorted deterministic)
    for entry in doubled.entries() {
        let (k, v) = entry
        print("${k}=${v}")
    }
}
