// Regression test for #54: impl inside mod block
// Verifies that impl methods are registered under the qualified type name

mod shapes {
    pub struct Circle {
        pub radius: Int,
    }

    pub impl Circle {
        pub fn area(self) -> Int {
            self.radius * self.radius * 3
        }
    }

    pub enum Color {
        Red,
        Green,
        Blue,
    }

    pub fn color_name(c: Color) -> Str {
        match c {
            Color::Red => "red",
            Color::Green => "green",
            Color::Blue => "blue",
        }
    }
}

fn main() {
    // #54: impl method call on mod-qualified struct
    let c = shapes::Circle { radius: 5 }
    print(c.area())

    // #55: qualified type in function parameter/return type (tested via color_name)
    let r = shapes::Color::Red
    print(shapes::color_name(r))

    // #56: two-level qualified access mod::Enum::Variant
    let g = shapes::Color::Green
    print(shapes::color_name(g))
}
