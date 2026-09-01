enum Op {
    Add,
    Eq
}

enum Color {
    Red,
    Green { shade: Int }
}

struct Empty {}

fn op_name(op: Op) -> Str {
    if op == Op::Eq {
        return "eq"
    }
    if op == Op::Add {
        return "add"
    }
    "unknown"
}

fn main() {
    assert(op_name(Op::Eq) == "eq", "eq variant comparison + block")
    assert(op_name(Op::Add) == "add", "add variant comparison + block")

    // Named-field variant construction in normal expression context — still works
    let g = Color::Green { shade: 50 }
    match g {
        Color::Green { shade } => assert(shade == 50, "named field variant"),
        _ => assert(false, "unreachable"),
    }

    // Bare variant comparison + block
    let c = Color::Red
    let mut found = false
    if c == Color::Red {
        found = true
    }
    assert(found, "bare variant comparison + block")

    // Empty struct construction in normal expression context — still works
    let e = Empty {}

    // Struct literal inside function call arguments — still works (parenthesized context)
    let g2 = Color::Green { shade: 100 }

    // while with enum comparison
    let mut count = 0
    let target = Op::Eq
    while target == Op::Eq {
        count = count + 1
        break
    }
    assert(count == 1, "while with enum comparison")

    print("enum_variant_brace_disambig: all tests passed")
}
