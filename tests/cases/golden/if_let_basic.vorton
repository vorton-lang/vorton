// B-100 P1.1 parity: if-let destructuring on Option and custom enums.



enum MyOption { Some(Int), None }

enum Shape {
    Circle { radius: Int },
    Rect { width: Int, height: Int },
    Point,
}

fn main() {
    // if-let with built-in Option — some branch
    let x: Int? = some(42)
    if let some(v) = x {
        print("opt_some=${v}")
    } else {
        print("opt_some=FAIL")
    }

    // if-let with built-in Option — none branch
    let y: Int? = none
    if let some(v) = y {
        print("opt_none=FAIL")
    } else {
        print("opt_none=was_none")
    }

    // if-let with custom enum — positional payload
    let m = MyOption::Some(99)
    if let MyOption::Some(v) = m {
        print("custom_some=${v}")
    } else {
        print("custom_some=FAIL")
    }

    // if-let with custom enum — non-matching
    let n = MyOption::None
    if let MyOption::Some(v) = n {
        print("custom_none=FAIL")
    } else {
        print("custom_none=was_none")
    }

    // if-let with named-field enum variant
    let s = Circle { radius: 5 }
    if let Circle { radius: r } = s {
        print("circle_r=${r}")
    } else {
        print("circle_r=FAIL")
    }

    // if-let non-matching named-field variant
    let s2 = Rect { width: 3, height: 4 }
    if let Circle { radius: r } = s2 {
        print("rect_as_circle=FAIL")
    } else {
        print("rect_as_circle=no_match")
    }

    // if-let with unit variant
    let s3 = Shape::Point
    if let Point = s3 {
        print("unit_match=yes")
    } else {
        print("unit_match=FAIL")
    }

    // if-let without else (no-else branch)
    let z: Int? = some(7)
    if let some(v) = z {
        print("no_else=${v}")
    }
}
