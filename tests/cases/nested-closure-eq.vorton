// Regression test: == in nested closures (bidirectional type propagation)
// Covers: double-nested closures, struct field access, multiple HOF nesting levels

struct Named { name: Str, value: Int }

fn main() {
    // Case 1: basic double-nested closure with ==
    let names = ["a", "b", "c"]
    let targets = ["a", "c"]
    let results = names.filter(fn(name) {
        targets.any(fn(t) { t == name })
    })
    assert(results.len() == 2, "case 1: basic nested closure eq")

    // Case 2: struct field access in nested closure
    let haystack = [Named { name: "x", value: 1 }, Named { name: "y", value: 2 }]
    let needles = [Named { name: "y", value: 0 }]
    let found = needles.all(fn(n) {
        haystack.any(fn(h) { h.name == n.name })
    })
    assert(found, "case 2: nested closure struct field eq")

    // Case 3: != in nested closure
    let excluded = names.filter(fn(name) {
        targets.all(fn(t) { t != name })
    })
    assert(excluded.len() == 1, "case 3: nested closure !=")
    assert(excluded.get(0).unwrap_or("?") == "b", "case 3: excluded element is b")

    print("nested closure eq: all passed")
}
