enum Shape { Circle(Float), Rect(Float, Float), Empty }

fn main() {
    let s1 = Circle(3.14)
    let s2 = s1.clone()
    assert(s1 == s2, "clone enum with field")
    let e = Shape::Empty
    let e2 = e.clone()
    assert(e == e2, "clone unit variant")
    print("clone_enum: all tests passed")
}
