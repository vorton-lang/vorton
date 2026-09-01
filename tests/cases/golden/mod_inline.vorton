// B-100 P1.1: inline module parity — qualified calls, module-level struct/enum.
// Tests that the LLVM backend correctly resolves module-qualified paths for
// functions, struct constructors, and enum variant patterns.

pub mod math {
    pub fn add(a: Int, b: Int) -> Int { a + b }
    pub fn mul(a: Int, b: Int) -> Int { a * b }

    pub struct Point {
        pub x: Int,
        pub y: Int,
    }

    pub enum Shape {
        Circle(Int),
        Rect(Int, Int),
    }

    pub fn area(s: Shape) -> Int {
        match s {
            Shape::Circle(r) => r * r * 3,
            Shape::Rect(w, h) => w * h,
        }
    }
}

pub mod greet {
    pub fn hello(name: Str) -> Str { "hello, ${name}" }
}

fn main() {
    // module-qualified function calls
    print(math::add(3, 4))
    print(math::mul(5, 6))

    // module-qualified struct construction and field access
    let p = math::Point { x: 10, y: 20 }
    print(p.x)
    print(p.y)

    // module-qualified enum construction
    let c = math::Shape::Circle(5)
    let r = math::Shape::Rect(3, 7)
    print(math::area(c))
    print(math::area(r))

    // second module
    print(greet::hello("world"))

    // module function in expression context
    let sum = math::add(math::mul(2, 3), math::add(4, 5))
    print(sum)
}
