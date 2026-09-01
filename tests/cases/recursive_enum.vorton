// Test: recursive enum types (self-referential through fields)

enum Expr {
    Lit(Int),
    Neg(Expr),
    Add { left: Expr, right: Expr }
}

fn eval(e: Expr) -> Int {
    match e {
        Lit(n) => n,
        Neg(inner) => 0 - eval(inner),
        Add { left, right } => eval(left) + eval(right)
    }
}

fn main() {
    let e1 = Lit(42)
    assert(eval(e1) == 42, "lit")

    let e2 = Neg(Lit(5))
    assert(eval(e2) == -5, "neg")

    // 1 + (-(2 + 3)) = 1 + (-5) = -4
    let e3 = Add {
        left: Lit(1),
        right: Neg(Add { left: Lit(2), right: Lit(3) })
    }
    assert(eval(e3) == -4, "nested recursive")

    print("recursive_enum: all tests passed")
}
