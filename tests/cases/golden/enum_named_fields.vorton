// B-100 P1.1 parity: enum named fields — declaration, construction, pattern
// matching with punning, explicit binding, partial match (..), and mixed
// positional + named field variants.

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

// Mixed positional and named fields
enum Expr {
    Lit(Int),
    Add { left: Int, right: Int },
    Neg(Int),
}

fn eval(e: Expr) -> Int {
    match e {
        Lit(n) => n,
        Add { left, right } => left + right,
        Neg(n) => 0 - n,
    }
}

fn main() {
    // Named field construction and matching
    let c = Circle { radius: 5 }
    let r = Rect { width: 3, height: 4 }
    let p = Point
    print("circle=${area(c)}")
    print("rect=${area(r)}")
    print("point=${area(p)}")

    // Explicit binding in pattern (not punning)
    let r2 = Rect { width: 7, height: 8 }
    match r2 {
        Rect { width: w, height: h } => print("explicit=${w * h}"),
        _ => print("unreachable"),
    }

    // Partial match with ..
    match c {
        Circle { .. } => print("partial=ok"),
        _ => print("partial=fail"),
    }

    // Construction with punning (variable name matches field name)
    let width = 10
    let height = 20
    let r3 = Rect { width, height }
    print("punned=${area(r3)}")

    // Mixed positional + named
    print("lit=${eval(Lit(10))}")
    print("add=${eval(Add { left: 3, right: 7 })}")
    print("neg=${eval(Neg(5))}")
}
