struct Point { x: Int, y: Int }

fn main() {
    let a = Point { x: 1, y: 2 }
    let b = Point { x: 1, y: 2 }
    let c = Point { x: 3, y: 4 }
    assert(a == b, "same fields should be equal")
    assert(a != c, "different fields should not be equal")
    assert(!(a == c), "negated eq")
    assert(1 == 1, "primitive int eq still works")
    assert("hello" == "hello", "primitive str eq still works")
    assert(true == true, "primitive bool eq still works")
    print("eq_struct: all tests passed")
}
