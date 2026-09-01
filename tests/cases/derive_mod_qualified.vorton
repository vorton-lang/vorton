// Regression test for #70: auto-derive generates invalid identifiers
// for mod-qualified field types (e.g. shapes::Circle produces __shapes::Circle_Eq
// instead of __shapes$Circle_Eq)

mod shapes {
    pub struct Circle {
        pub radius: Int
    }
}

struct Drawing {
    shape: shapes::Circle
}

fn main() {
    let d1 = Drawing { shape: shapes::Circle { radius: 5 } }
    let d2 = Drawing { shape: shapes::Circle { radius: 5 } }
    let d3 = Drawing { shape: shapes::Circle { radius: 10 } }

    // Eq
    assert(d1 == d2, "same drawings should be equal")
    assert(d1 != d3, "different drawings should not be equal")

    // Clone
    let d4 = d1.clone()
    assert(d4 == d1, "cloned drawing should be equal")

    // Debug
    let s = d1.debug()
    assert(s.contains("5"), "debug should contain radius value")

    // Ord
    let c = d1.cmp(d3)
    assert(c < 0, "d1 radius 5 < d3 radius 10")

    print("ok")
}
