fn main() {
    let a = (1, 2)
    let b = (1, 2)
    assert(a == b, "tuple eq same values")
    assert((1, 2) == (1, 2), "tuple eq literal")
    assert((1, 2) != (3, 4), "tuple neq different")
    assert((1, 2) != (1, 3), "tuple neq partial")
    assert((1, 2, 3) == (1, 2, 3), "triple eq")
    let c = (1, (2, 3))
    let d = (1, (2, 3))
    assert(c == d, "nested tuple eq")
    assert(c != (1, (2, 4)), "nested tuple neq")
    print("tuple_eq: all tests passed")
}
