// Guards over enum constructor patterns where multiple arms share the same
// constructor/tag. A switch cannot express this (one tag -> one case, no
// fall-through), so the LLVM backend must lower a guarded enum match through
// the if-else chain: test the tag, evaluate the guard, and fall through to the
// next arm (re-testing its tag+guard) when the guard is false.
enum Shape {
    Circle { r: Int },
    Rect { w: Int, h: Int }
}

fn describe(sh: Shape) -> Str {
    match sh {
        Shape::Circle { r } if r > 100 => "huge circle",
        Shape::Circle { r } if r > 10 => "big circle",
        Shape::Circle { r } => "small circle r=${r}",
        Shape::Rect { w, h } if w == h => "square ${w}x${h}",
        Shape::Rect { w, h } if w > h => "wide rect",
        Shape::Rect { w, h } => "tall rect ${w}x${h}"
    }
}

fn main() {
    print(describe(Shape::Circle { r: 500 }))     // huge circle
    print(describe(Shape::Circle { r: 50 }))      // big circle
    print(describe(Shape::Circle { r: 3 }))       // small circle r=3
    print(describe(Shape::Rect { w: 4, h: 4 }))   // square 4x4
    print(describe(Shape::Rect { w: 8, h: 2 }))   // wide rect
    print(describe(Shape::Rect { w: 2, h: 8 }))   // tall rect 2x8
}
