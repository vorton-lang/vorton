// Regression test for #56: two-level qualified enum variant access

mod colors {
    pub enum Color {
        Red,
        Green(Int),
        Blue { r: Int, g: Int, b: Int },
    }
}

fn describe(c: colors::Color) -> Str {
    match c {
        colors::Color::Red => "red",
        colors::Color::Green(n) => "green-${n.to_str()}",
        colors::Color::Blue { r, g, b } => "${r.to_str()}-${g.to_str()}-${b.to_str()}",
    }
}

fn main() {
    print(describe(colors::Color::Red))
    print(describe(colors::Color::Green(42)))
    print(describe(colors::Color::Blue { r: 1, g: 2, b: 3 }))
}
