// Test: method chaining on List — filter.map.fold etc.

fn main() {
    let xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    // filter then map then fold
    let result = xs
        .filter(fn(x) { x % 2 == 0 })
        .map(fn(x) { x * x })
        .fold(0, fn(acc, x) { acc + x })
    // evens: 2,4,6,8,10 -> squared: 4,16,36,64,100 -> sum: 220
    assert(result == 220, "filter.map.fold chain")

    // map then filter
    let big = [1, 2, 3, 4, 5]
        .map(fn(x) { x * 10 })
        .filter(fn(x) { x > 30 })
    assert(big.len() == 2, "map.filter chain len")
    assert(big.get(0).unwrap_or(0) == 40, "map.filter [0]")

    // flat_map then fold
    let nested_sum = [1, 2, 3]
        .flat_map(fn(x) { [x, x + 10] })
        .fold(0, fn(acc, x) { acc + x })
    // [1,11,2,12,3,13] -> sum = 42
    assert(nested_sum == 42, "flat_map.fold chain")

    // join after map
    let joined = [1, 2, 3]
        .map(fn(x) { "${x}" })
        .join(", ")
    assert(joined == "1, 2, 3", "map.join")

    print("list_method_chain: all tests passed")
}
