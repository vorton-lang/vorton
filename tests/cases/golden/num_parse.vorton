// B-100 P1.1 parity: numeric parsing and formatting.
// parse_int, parse_float, Int.to_str, Float.to_str.

fn main() {
    // parse_int — valid
    let a = parse_int("42")
    match a {
        some(v) => print("parse_int_ok=${v}"),
        none => print("parse_int_ok=FAIL"),
    }

    // parse_int — invalid
    let b = parse_int("not_a_number")
    match b {
        some(v) => print("parse_int_bad=${v}"),
        none => print("parse_int_bad=none"),
    }

    // parse_int — negative
    let c = parse_int("-7")
    match c {
        some(v) => print("parse_int_neg=${v}"),
        none => print("parse_int_neg=FAIL"),
    }

    // parse_float — valid
    let d = parse_float("3.14")
    match d {
        some(v) => print("parse_float_ok=${v}"),
        none => print("parse_float_ok=FAIL"),
    }

    // parse_float — invalid
    let e = parse_float("abc")
    match e {
        some(v) => print("parse_float_bad=${v}"),
        none => print("parse_float_bad=none"),
    }

    // Int.to_str
    let x = 99
    print("int_to_str=${x.to_str()}")

    // Float.to_str
    let f = 2.75
    print("float_to_str=${f.to_str()}")

    // zero conversions
    print("zero_int=${0.to_str()}")
    print("zero_float=${0.0.to_str()}")
}
