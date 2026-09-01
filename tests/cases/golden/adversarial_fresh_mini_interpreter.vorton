// B-100 P1.3 R3 adversarial: mini interpreter — large combo test exercising
// enum, match, recursion, effect, trait dispatch, closures, and type aliases
// in a program that interprets a small expression language.
//
// Exercises:
//   * Recursive enum (Expr) with multiple variant shapes
//   * Recursive evaluation with pattern matching
//   * Custom effect for logging evaluation steps
//   * Trait for pretty-printing expressions
//   * Type aliases for readability
//   * Error handling via fail/catch for division by zero

type Value = Int

enum Expr {
    Lit(Value),
    Add(Expr, Expr),
    Mul(Expr, Expr),
    Div(Expr, Expr),
    Neg(Expr),
}

effect Trace {
    fn trace(msg: Str) -> Unit
}

fn eval(expr: Expr) -> Value with {fail<Str>, Trace} {
    match expr {
        Expr::Lit(n) => {
            Trace.trace("lit ${n}")
            n
        },
        Expr::Add(left, right) => {
            let l = eval(left)
            let r = eval(right)
            Trace.trace("add ${l} + ${r}")
            l + r
        },
        Expr::Mul(left, right) => {
            let l = eval(left)
            let r = eval(right)
            Trace.trace("mul ${l} * ${r}")
            l * r
        },
        Expr::Div(left, right) => {
            let l = eval(left)
            let r = eval(right)
            if r == 0 {
                fail.raise("division by zero")
            }
            Trace.trace("div ${l} / ${r}")
            l / r
        },
        Expr::Neg(inner) => {
            let v = eval(inner)
            Trace.trace("neg ${v}")
            0 - v
        },
    }
}

trait Show {
    fn show(self) -> Str
}

impl Show for Expr {
    fn show(self) -> Str {
        match self {
            Expr::Lit(n) => n.to_str(),
            Expr::Add(l, r) => "(${l.show()} + ${r.show()})",
            Expr::Mul(l, r) => "(${l.show()} * ${r.show()})",
            Expr::Div(l, r) => "(${l.show()} / ${r.show()})",
            Expr::Neg(e) => "(- ${e.show()})",
        }
    }
}

fn run_eval(expr: Expr) -> Str {
    let result: Value = handle {
        eval(expr) catch { e => -9999 }
    } with {
        Trace.trace(msg) => {},
    }
    if result == -9999 {
        "ERROR"
    } else {
        result.to_str()
    }
}

fn run_eval_traced(expr: Expr) -> Str {
    let result: Value = handle {
        eval(expr) catch { e => -9999 }
    } with {
        Trace.trace(msg) => print("  trace: ${msg}"),
    }
    if result == -9999 {
        "ERROR"
    } else {
        result.to_str()
    }
}

fn main() {
    // Test 1: simple literal
    let e1 = Expr::Lit(42)
    print("show1=${e1.show()}")
    print("eval1=${run_eval(e1)}")

    // Test 2: addition
    let e2 = Expr::Add(Expr::Lit(10), Expr::Lit(20))
    print("show2=${e2.show()}")
    print("eval2=${run_eval(e2)}")

    // Test 3: nested arithmetic: (3 + 4) * 5
    let e3 = Expr::Mul(
        Expr::Add(Expr::Lit(3), Expr::Lit(4)),
        Expr::Lit(5)
    )
    print("show3=${e3.show()}")
    print("eval3=${run_eval(e3)}")

    // Test 4: negation
    let e4 = Expr::Neg(Expr::Lit(7))
    print("eval4=${run_eval(e4)}")

    // Test 5: division
    let e5 = Expr::Div(Expr::Lit(100), Expr::Lit(4))
    print("eval5=${run_eval(e5)}")

    // Test 6: division by zero (fail effect + catch)
    let e6 = Expr::Div(Expr::Lit(10), Expr::Lit(0))
    print("eval6=${run_eval(e6)}")

    // Test 7: complex expression — (10 + (- 3)) * 2
    let e7 = Expr::Mul(
        Expr::Add(Expr::Lit(10), Expr::Neg(Expr::Lit(3))),
        Expr::Lit(2)
    )
    print("show7=${e7.show()}")
    print("eval7=${run_eval(e7)}")

    // Test 8: deeply nested — ((2 * 3) + (4 * 5)) + Neg(1)
    let e8 = Expr::Add(
        Expr::Add(
            Expr::Mul(Expr::Lit(2), Expr::Lit(3)),
            Expr::Mul(Expr::Lit(4), Expr::Lit(5))
        ),
        Expr::Neg(Expr::Lit(1))
    )
    print("eval8=${run_eval(e8)}")

    // Test 9: traced evaluation to exercise the effect handler
    let e9 = Expr::Add(Expr::Lit(1), Expr::Lit(2))
    print("eval9_traced:")
    let r9 = run_eval_traced(e9)
    print("result9=${r9}")
}
