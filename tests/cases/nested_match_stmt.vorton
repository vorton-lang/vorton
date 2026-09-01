// Regression: nested match in statement context must use unique labels
fn main() {
    let x: Option<Option<Int>> = some(some(42))
    match x {
        some(inner) => match inner {
            some(v) => print(v),
            none => print("inner none"),
        },
        none => print("outer none"),
    }

    // Triple nesting
    let y: Option<Option<Option<Str>>> = some(some(some("deep")))
    match y {
        some(a) => match a {
            some(b) => match b {
                some(s) => print(s),
                none => print("none3"),
            },
            none => print("none2"),
        },
        none => print("none1"),
    }
}
