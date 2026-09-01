// #181 regression: literal or-patterns in match (previously crashed LLVM codegen)
// Tests: int literal or-pattern, string literal or-pattern, mixed with wildcards

fn classify(n: Int) -> Str {
    match n {
        0 | 1 => "tiny",
        2 | 3 | 4 => "small",
        5 => "five",
        _ => "big",
    }
}

fn describe_str(s: Str) -> Str {
    match s {
        "a" | "b" | "c" => "early",
        "x" | "y" | "z" => "late",
        _ => "other",
    }
}

fn bool_match(b: Bool) -> Str {
    match b {
        true => "yes",
        false => "no",
    }
}

fn main() {
    print("c0=${classify(0)}")
    print("c1=${classify(1)}")
    print("c2=${classify(2)}")
    print("c3=${classify(3)}")
    print("c4=${classify(4)}")
    print("c5=${classify(5)}")
    print("c9=${classify(9)}")

    print("sa=${describe_str("a")}")
    print("sb=${describe_str("b")}")
    print("sc=${describe_str("c")}")
    print("sx=${describe_str("x")}")
    print("sy=${describe_str("y")}")
    print("sm=${describe_str("m")}")

    print("bt=${bool_match(true)}")
    print("bf=${bool_match(false)}")
}
