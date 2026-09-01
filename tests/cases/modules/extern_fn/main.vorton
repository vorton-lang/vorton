use utils::{parse_int, parse_float, parse_and_double}

fn main() {
    match parse_int("100") {
        some(x) => print(x),
        none => print("error"),
    }
    match parse_float("2.5") {
        some(y) => print(y),
        none => print("error"),
    }
    let z = parse_and_double("21")
    print(z)
}

// expect: 100
// expect: 2.5
// expect: 42
