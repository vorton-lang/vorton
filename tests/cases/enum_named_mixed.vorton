// Test: Enum with mixed positional and named field variants

enum Expr {
    Lit(Int),
    Add { left: Int, right: Int },
    Neg(Int),
}

fn eval(e: Expr) -> Int {
    match e {
        Lit(n) => n,
        Add { left, right } => left + right,
        Neg(n) => 0 - n,
    }
}

fn main() {
    let a = Lit(10)
    let b = Add { left: 3, right: 7 }
    let c = Neg(5)

    assert(eval(a) == 10, "lit eval")
    assert(eval(b) == 10, "add eval")
    assert(eval(c) == -5, "neg eval")

    print("enum_named_mixed: all tests passed")
}
