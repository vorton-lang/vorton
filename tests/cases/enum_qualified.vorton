enum Color {
    red,
    green,
    blue,
}

enum Shape {
    Circle { radius: Int },
    Point,
}

fn main() {
    // Qualified zero-field variant
    let c = Color::red

    // Qualified with call syntax
    let opt = Option::some(42)

    // Qualified named variant
    let s = Shape::Circle { radius: 5 }

    // Qualified unit variant (no parens in declaration)
    let p = Shape::Point

    // Qualified in match — bare name
    match c {
        Color::red => print("red"),
        Color::green => print("green"),
        Color::blue => print("blue"),
    }

    // Qualified Option match
    match opt {
        Option::some(v) => assert(v == 42, "qualified some"),
        Option::none => assert(false, "should not be none"),
    }

    // Qualified named pattern
    match s {
        Shape::Circle { radius } => assert(radius == 5, "qualified named"),
        Shape::Point => assert(false, "not point"),
    }

    // Mixed qualified and unqualified in same match
    let opt2 = some(10)
    match opt2 {
        Option::some(v) => assert(v == 10, "mixed match"),
        none => assert(false, "not none"),
    }

    print("enum_qualified: all tests passed")
}
