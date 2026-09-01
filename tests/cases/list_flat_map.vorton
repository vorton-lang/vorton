// Test: List.flat_map, List.find, List.find_index, List.any, List.all

fn main() {
    // flat_map
    let xs = [1, 2, 3]
    let result = xs.flat_map(fn(x) { [x, x * 10] })
    assert(result.len() == 6, "flat_map len")
    assert(result.get(0).unwrap_or(0) == 1, "flat_map [0]")
    assert(result.get(1).unwrap_or(0) == 10, "flat_map [1]")
    assert(result.get(2).unwrap_or(0) == 2, "flat_map [2]")
    assert(result.get(5).unwrap_or(0) == 30, "flat_map [5]")

    // find
    let found = [10, 20, 30].find(fn(x) { x > 15 })
    assert(found.unwrap_or(0) == 20, "find first > 15")

    let not_found = [1, 2, 3].find(fn(x) { x > 10 })
    assert(not_found.is_none(), "find none")

    // find_index
    let idx = [10, 20, 30].find_index(fn(x) { x == 20 })
    assert(idx.unwrap_or(-1) == 1, "find_index 20")

    let no_idx = [10, 20, 30].find_index(fn(x) { x == 99 })
    assert(no_idx.is_none(), "find_index none")

    // any
    assert([1, 2, 3].any(fn(x) { x == 2 }), "any true")
    assert(![1, 2, 3].any(fn(x) { x == 5 }), "any false")

    // all
    assert([2, 4, 6].all(fn(x) { x % 2 == 0 }), "all true")
    assert(![1, 2, 3].all(fn(x) { x % 2 == 0 }), "all false")

    print("list_flat_map: all tests passed")
}
