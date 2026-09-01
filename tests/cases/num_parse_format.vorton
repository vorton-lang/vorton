// Test: parse_int, parse_float, Int.to_str, Float.to_str
fn main() {
    let a = parse_int("42")
    match a {
        some(v) => print(v)
        none => print(0)
    }

    let b = parse_int("not_a_number")
    match b {
        some(v) => print(v)
        none => print(-1)
    }

    let c = parse_float("3.14")
    match c {
        some(v) => print(v)
        none => print(0)
    }

    let x = 99
    let s = x.to_str()
    print(s)
}

// expect: 42
// expect: -1
// expect: 3.14
// expect: 99
