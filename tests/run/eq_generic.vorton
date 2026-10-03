struct Pair<A, B> { a: A, b: B }

fn main() {
    let p1 = Pair { a: 1, b: "x" }
    let p2 = Pair { a: 1, b: "x" }
    let p3 = Pair { a: 2, b: "y" }
    assert(p1 == p2, "generic struct eq")
    assert(p1 != p3, "generic struct ne")
    print("eq_generic: all tests passed")
}
