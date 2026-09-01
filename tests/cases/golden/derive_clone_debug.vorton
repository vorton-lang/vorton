// B-100 P1.1: Clone + Debug derive parity — struct clone, enum clone, and
// debug() output for structs and enums.
//
// NOTE: .clone() and .debug() have not been tested in llvm_diff before.
// This test surfaces any LLVM backend gaps in auto-derived trait methods.

struct Point { x: Int, y: Int }

enum Color {
    Red,
    Blue,
    Green,
}

enum Shape {
    Circle(Int),
    Rect(Int, Int),
}

struct Pair { a: Str, b: Int }

fn main() {
    // struct Clone
    let p1 = Point { x: 1, y: 2 }
    let p2 = p1.clone()
    print(p2.x)
    print(p2.y)
    print(p1 == p2)

    // enum Clone — unit variant
    let c1 = Color::Red
    let c2 = c1.clone()
    print(c1 == c2)

    // enum Clone — tuple variant
    let s1 = Shape::Circle(5)
    let s2 = s1.clone()
    print(s1 == s2)

    // struct Debug
    let p3 = Point { x: 10, y: 20 }
    print(p3.debug())

    // enum Debug — unit variant
    print(Color::Blue.debug())

    // enum Debug — tuple variant
    print(Shape::Circle(7).debug())
    print(Shape::Rect(3, 4).debug())

    // struct with Str field Debug
    let pair = Pair { a: "hello", b: 42 }
    print(pair.debug())

    // clone and use
    let pair2 = pair.clone()
    print(pair2.a)
    print(pair2.b)
}
