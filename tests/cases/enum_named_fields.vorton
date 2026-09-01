// Test: Enum named fields — declaration, construction, pattern matching, punning

enum Shape {
    Circle { radius: Int },
    Rect { width: Int, height: Int },
    Point,
}

fn area(s: Shape) -> Int {
    match s {
        Circle { radius } => radius * radius * 3,
        Rect { width, height } => width * height,
        Point => 0,
    }
}

fn main() {
    let c = Circle { radius: 5 }
    let r = Rect { width: 3, height: 4 }
    let p = Point

    assert(area(c) == 75, "circle area")
    assert(area(r) == 12, "rect area")
    assert(area(p) == 0, "point area")

    // Explicit binding in pattern (not punning)
    match r {
        Rect { width: w, height: h } => {
            assert(w == 3, "rect width")
            assert(h == 4, "rect height")
        },
        _ => assert(false, "unreachable"),
    }

    // Partial match with ..
    match c {
        Circle { .. } => assert(true, "partial match"),
        _ => assert(false, "unreachable"),
    }

    // Construction with punning
    let w = 10
    let h = 20
    let r2 = Rect { width: w, height: h }
    assert(area(r2) == 200, "punned rect area")

    print("enum_named_fields: all tests passed")
}
