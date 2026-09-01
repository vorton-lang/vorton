// Regression C2: nested constructor patterns
fn describe(x: Int?) -> Str {
    match x {
        some(v) if v > 0 => "positive",
        some(v) => "non-positive",
        none => "nothing",
    }
}

fn main() {
    print(describe(some(42)))
    print(describe(some(-1)))
    print(describe(none))
}
