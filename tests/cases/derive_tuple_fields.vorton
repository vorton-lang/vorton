struct Wrapper {
    data: (Int, Int)
}

struct Nested {
    pair: (Str, Bool)
}

fn main() {
    // Eq: same tuples should be equal
    let a = Wrapper { data: (1, 2) }
    let b = Wrapper { data: (1, 2) }
    let c = Wrapper { data: (3, 4) }
    assert(a == b, "same tuple should be equal")
    assert(a != c, "different tuple should not be equal")

    // Eq: different element types
    let n1 = Nested { pair: ("hello", true) }
    let n2 = Nested { pair: ("hello", true) }
    let n3 = Nested { pair: ("world", false) }
    assert(n1 == n2, "same nested tuple should be equal")
    assert(n1 != n3, "different nested tuple should not be equal")

    // Clone: cloned struct should be equal but independent
    let d = a.clone()
    assert(d == a, "clone should produce equal value")

    // Debug: should produce readable output
    let dbg = a.debug()
    assert(dbg.len() > 0, "debug should produce non-empty string")

    print("pass: derive tuple")
}
