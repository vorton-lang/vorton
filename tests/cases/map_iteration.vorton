// Test: Map iteration methods — map_values, filter, fold, any
// NOTE: Str UFCS methods inside HOF lambdas have a codegen bug (to_upper etc.)
//       so we use Int values to avoid triggering it

fn main() {
    let m = map_from([(1, 10), (2, 20), (3, 30)])

    // map_values
    let doubled = m.map_values(fn(v) { v * 2 })
    assert(doubled.get(1).unwrap_or(0) == 20, "map_values 1")
    assert(doubled.get(2).unwrap_or(0) == 40, "map_values 2")
    assert(doubled.get(3).unwrap_or(0) == 60, "map_values 3")

    // filter
    let big = m.filter(fn(k, v) { v > 10 })
    assert(big.len() == 2, "map filter len")
    assert(!big.contains_key(1), "map filter removed 1")
    assert(big.contains_key(2), "map filter kept 2")
    assert(big.contains_key(3), "map filter kept 3")

    // fold
    let sum = m.fold(0, fn(acc, k, v) { acc + v })
    assert(sum == 60, "map fold sum values")

    // any
    assert(m.any(fn(k, v) { k == 2 }), "map any true")
    assert(!m.any(fn(k, v) { k > 10 }), "map any false")

    // keys and values
    let keys = m.keys()
    assert(keys.len() == 3, "map keys len")

    let values = m.values()
    assert(values.len() == 3, "map values len")

    // entries iteration via for
    let m2 = map_from([("a", 1), ("b", 2)])
    let mut key_sum = 0
    for (k, v) in m2 {
        key_sum = key_sum + v
    }
    assert(key_sum == 3, "map for destructure sum")

    print("map_iteration: all tests passed")
}
