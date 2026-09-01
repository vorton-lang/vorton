// B-100 P1.1 parity: sort_by — custom comparator sorting via sort_by,
// ascending/descending. sort_by takes (T, T) -> Int comparator.

struct Item { name: Str, value: Int }

fn main() {
    // Sort by custom comparator — ascending (a - b)
    let mut xs = [5, 3, 8, 1, 9, 2]
    xs.sort_by(fn(a, b) { a - b })
    print("asc_first=${xs[0]}")
    print("asc_last=${xs[xs.len() - 1]}")

    // Sort by custom comparator — descending (b - a)
    let mut ys = [5, 3, 8, 1, 9, 2]
    ys.sort_by(fn(a, b) { b - a })
    print("desc_first=${ys[0]}")
    print("desc_last=${ys[ys.len() - 1]}")

    // Sort structs by field value
    let mut items = [
        Item { name: "c", value: 30 },
        Item { name: "a", value: 10 },
        Item { name: "b", value: 20 },
    ]
    items.sort_by(fn(a, b) { a.value - b.value })
    print("by_val_first=${items[0].name}")
    print("by_val_last=${items[items.len() - 1].name}")

    // Sort by string length
    let mut words = ["hello", "hi", "hey"]
    words.sort_by(fn(a, b) { a.len() - b.len() })
    print("by_len_first=${words[0]}")
    print("by_len_last=${words[words.len() - 1]}")

    // Already sorted list
    let mut sorted = [1, 2, 3, 4, 5]
    sorted.sort_by(fn(a, b) { a - b })
    print("already_sorted=${sorted[0]},${sorted[4]}")

    // Single element
    let mut single = [42]
    single.sort_by(fn(a, b) { a - b })
    print("single=${single[0]}")
}
