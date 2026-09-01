// B-100 P1.1 parity: iterator protocol — map, filter, any, all on List.
// Includes chained HOF calls.

fn main() {
    let xs = [1, 2, 3, 4, 5]

    // map
    let doubled = xs.map(fn(x) { x * 2 })
    print("map=${doubled.len()}")                     // map=5
    for v in doubled { print(v) }                     // 2 4 6 8 10

    // filter
    let evens = xs.filter(fn(x) { x % 2 == 0 })
    print("filter_len=${evens.len()}")                // filter_len=2
    for v in evens { print(v) }                       // 2 4

    // any
    let has_big = xs.any(fn(x) { x > 4 })
    print("any_true=${has_big}")                      // any_true=true
    let has_neg = xs.any(fn(x) { x < 0 })
    print("any_false=${has_neg}")                     // any_false=false

    // all
    let all_pos = xs.all(fn(x) { x > 0 })
    print("all_true=${all_pos}")                      // all_true=true
    let all_big = xs.all(fn(x) { x > 3 })
    print("all_false=${all_big}")                     // all_false=false

    // chained: filter then map
    let chained = [1, 2, 3, 4, 5, 6]
        .filter(fn(x) { x > 2 })
        .map(fn(x) { x * 10 })
    for v in chained { print(v) }                     // 30 40 50 60

    // fold
    let sum = xs.fold(0, fn(acc, x) { acc + x })
    print("fold_sum=${sum}")                          // fold_sum=15

    // find
    let found = xs.find(fn(x) { x == 3 })
    print("find=${found.unwrap_or(-1)}")              // find=3

    // find_index
    let idx = xs.find_index(fn(x) { x == 4 })
    print("find_index=${idx.unwrap_or(-1)}")          // find_index=3
}
