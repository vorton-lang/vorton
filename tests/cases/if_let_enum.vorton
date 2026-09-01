// Test: if-let with enum variants (not just Option)

enum Shape {
    Circle { radius: Int },
    Rect { width: Int, height: Int },
    Point,
}

fn main() {
    let s1 = Circle { radius: 5 }
    let s2 = Rect { width: 3, height: 4 }
    let s3 = Point

    // if-let with named fields
    if let Circle { radius: r } = s1 {
        assert(r == 5, "if-let circle radius")
    } else {
        assert(false, "should be circle")
    }

    // if-let non-matching
    if let Circle { radius: r } = s2 {
        assert(false, "should not match")
    } else {
        assert(true, "rect is not circle")
    }

    // if-let with unit variant
    if let Point = s3 {
        assert(true, "matched point")
    } else {
        assert(false, "should be point")
    }

    // Nested option with if-let
    let opt: Option<Int> = some(42)
    let mut found = 0
    if let some(v) = opt {
        found = v
    }
    assert(found == 42, "if-let option some")

    print("if_let_enum: all tests passed")
}
