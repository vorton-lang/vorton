// #198: negative numeric literal patterns in match
fn classify(x: Int) -> Str {
    match x {
        -1 => "minus one",
        0 => "zero",
        1 => "one",
        _ => "other",
    }
}

fn classify_float(x: Float) -> Str {
    match x {
        -1.5 => "minus one point five",
        0.0 => "zero",
        1.5 => "one point five",
        _ => "other",
    }
}

fn main() {
    print(classify(-1))
    print(classify(0))
    print(classify(1))
    print(classify(42))
    print(classify_float(-1.5))
    print(classify_float(0.0))
    print(classify_float(1.5))
    print(classify_float(3.14))
}
