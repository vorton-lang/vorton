// Test: deeply nested pattern matching — multi-level enum patterns

enum Expr {
    Lit(Int),
    Neg(Expr),
    Add { left: Expr, right: Expr },
}

// Pattern match on nested constructors
fn simplify(e: Expr) -> Expr {
    match e {
        // Double negation elimination
        Neg(Neg(inner)) => simplify(inner),
        // Negation of literal
        Neg(Lit(n)) => Lit(0 - n),
        // Add of two literals
        Add { left: Lit(a), right: Lit(b) } => Lit(a + b),
        // Recurse into Add
        Add { left, right } => Add { left: simplify(left), right: simplify(right) },
        _ => e,
    }
}

fn eval(e: Expr) -> Int {
    match e {
        Lit(n) => n,
        Neg(inner) => 0 - eval(inner),
        Add { left, right } => eval(left) + eval(right),
    }
}

fn main() {
    // Double negation
    let e1 = Neg(Neg(Lit(5)))
    assert(eval(simplify(e1)) == 5, "double neg simplify")

    // Neg of literal
    let e2 = Neg(Lit(3))
    assert(eval(simplify(e2)) == -3, "neg lit simplify")

    // Add of two literals
    let e3 = Add { left: Lit(2), right: Lit(3) }
    assert(eval(simplify(e3)) == 5, "add lit simplify")

    // Nested: Add { left: Neg(Neg(Lit(1))), right: Lit(4) }
    let e4 = Add { left: Neg(Neg(Lit(1))), right: Lit(4) }
    assert(eval(simplify(e4)) == 5, "nested simplify")

    print("match_enum_deep: all tests passed")
}
