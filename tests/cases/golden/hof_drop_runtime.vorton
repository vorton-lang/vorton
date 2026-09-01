// HOF runtime drop regression test for audit #152
// Tests that predicate Bool, fold accumulator, and for_each synthesized keys
// are properly dropped (no leak).

fn main() {
    // ① filter/any/all/find/find_index predicate Bool drop
    let xs = [1, 2, 3, 4, 5]
    let filtered = xs.filter(fn(x) { x > 2 })
    print("filtered=${filtered.len()}")

    let has_big = xs.any(fn(x) { x > 4 })
    print("any=${has_big}")

    let all_pos = xs.all(fn(x) { x > 0 })
    print("all=${all_pos}")

    let found = xs.find(fn(x) { x == 3 })
    print("find=${found.unwrap_or(-1)}")

    let idx = xs.find_index(fn(x) { x == 3 })
    print("find_index=${idx.unwrap_or(-1)}")

    // ② fold intermediate accumulator drop
    let sum = xs.fold(0, fn(acc, x) { acc + x })
    print("sum=${sum}")

    // Fold with string accumulator (heap-allocated, real leak before fix)
    let strs = ["a", "b", "c"]
    let joined = strs.fold("", fn(acc, s) { "${acc}${s}" })
    print("joined=${joined}")

    print("done")
}
