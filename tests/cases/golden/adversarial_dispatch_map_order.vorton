// B-100 P1.3 adversarial: Map iteration — carefully avoids order-dependence.
// C++ std::map has deterministic (sorted) iteration. B-089 G-b sorted
// iteration should ensure determinism, but we test with order-independent assertions.
// Also tests Map<Int, Str> and Map<Str, Int> variants.

fn main() {
    // ── Map<Str, Int> basic ops ──
    let mut m: Map<Str, Int> = map_new()
    m.insert("x", 10)
    m.insert("y", 20)
    m.insert("z", 30)

    // Order-independent: check length and individual gets
    print("map_len=${m.len()}")                      // map_len=3
    print("get_x=${m.get("x").unwrap_or(-1)}")       // get_x=10
    print("get_y=${m.get("y").unwrap_or(-1)}")       // get_y=20
    print("get_z=${m.get("z").unwrap_or(-1)}")       // get_z=30
    print("get_miss=${m.get("w").is_none()}")         // get_miss=true

    // Keys/values/entries — check via sorted approach
    let keys = m.keys()
    print("keys_len=${keys.len()}")                  // keys_len=3
    print("keys_has_x=${keys.contains("x")}")        // keys_has_x=true
    print("keys_has_y=${keys.contains("y")}")        // keys_has_y=true
    print("keys_has_z=${keys.contains("z")}")        // keys_has_z=true

    let vals = m.values()
    print("vals_len=${vals.len()}")                  // vals_len=3

    let entries = m.entries()
    print("entries_len=${entries.len()}")             // entries_len=3

    // ── Map<Int, Str> ──
    let mut mi: Map<Int, Str> = map_new()
    mi.insert(1, "one")
    mi.insert(2, "two")
    mi.insert(3, "three")
    print("mi_len=${mi.len()}")                      // mi_len=3
    print("mi_get1=${mi.get(1).unwrap_or("?")}")     // mi_get1=one
    print("mi_get2=${mi.get(2).unwrap_or("?")}")     // mi_get2=two

    // ── Overwrite key ──
    m.insert("x", 99)
    print("overwrite_x=${m.get("x").unwrap_or(-1)}") // overwrite_x=99
    print("overwrite_len=${m.len()}")                // overwrite_len=3

    // ── Remove key ──
    m.remove("y")
    print("after_remove_len=${m.len()}")             // after_remove_len=2
    print("removed_y=${m.get("y").is_none()}")       // removed_y=true

    // ── contains_key ──
    print("has_x=${m.contains_key("x")}")            // has_x=true
    print("has_y=${m.contains_key("y")}")            // has_y=false

    print("done")
}
