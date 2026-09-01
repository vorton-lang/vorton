// M16: Empty collection edge cases
fn main() {
    // Create empty list via filter ([] literal can't infer type)
    let empty = [1].filter(fn(x: Int) -> Bool { false })

    // HOF on empty list
    let mapped = empty.map(fn(x: Int) -> Int { x + 1 })
    print(mapped.len())

    let filtered = empty.filter(fn(x: Int) -> Bool { x > 0 })
    print(filtered.len())

    let folded = empty.fold(0, fn(acc: Int, x: Int) -> Int { acc + x })
    print(folded)

    print(empty.any(fn(x: Int) -> Bool { true }))
    print(empty.all(fn(x: Int) -> Bool { false }))

    // find on empty list
    let found = empty.find(fn(x: Int) -> Bool { true })
    match found {
        none => print("none"),
        some(v) => print(v),
    }

    // Str edge cases
    let s = ""
    print(s.len())
    print(s.contains("x"))

    // Set edge cases
    let empty_set = set_from(empty)
    print(empty_set.len())
    print(empty_set.contains(1))

    // Map edge cases
    let empty_map = map_new()
    print(empty_map.len())
    print(empty_map.contains_key("x"))
}
