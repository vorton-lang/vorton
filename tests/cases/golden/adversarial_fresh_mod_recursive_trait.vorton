// B-100 P1.3 R3 adversarial: module + recursive enum + trait — combining
// three features that haven't been tested together in llvm_diff.
//
// Exercises:
//   * Recursive enum defined inside a mod
//   * Trait defined in mod, impl for recursive enum in mod
//   * Recursive traversal of mod-internal enum from outside the mod
//   * Const in mod used during evaluation

mod ast {
    pub const ZERO_STR: Str = "0"

    pub enum Expr {
        Num(Int),
        Neg(Expr),
        Add(Expr, Expr),
        Mul(Expr, Expr),
    }

    pub trait Eval {
        fn eval(self) -> Int
    }

    pub impl Eval for Expr {
        fn eval(self) -> Int {
            match self {
                Expr::Num(n) => n,
                Expr::Neg(e) => 0 - e.eval(),
                Expr::Add(l, r) => l.eval() + r.eval(),
                Expr::Mul(l, r) => l.eval() * r.eval(),
            }
        }
    }
}

// Functions that operate on mod-internal types, defined outside the mod
fn depth(e: ast::Expr) -> Int {
    match e {
        ast::Expr::Num(_) => 0,
        ast::Expr::Neg(inner) => 1 + depth(inner),
        ast::Expr::Add(l, r) => {
            let ld = depth(l)
            let rd = depth(r)
            1 + if ld > rd { ld } else { rd }
        },
        ast::Expr::Mul(l, r) => {
            let ld = depth(l)
            let rd = depth(r)
            1 + if ld > rd { ld } else { rd }
        },
    }
}

fn show(e: ast::Expr) -> Str {
    match e {
        ast::Expr::Num(n) => n.to_str(),
        ast::Expr::Neg(inner) => "(-${show(inner)})",
        ast::Expr::Add(l, r) => "(${show(l)}+${show(r)})",
        ast::Expr::Mul(l, r) => "(${show(l)}*${show(r)})",
    }
}

fn main() {
    // Simple num
    let e1 = ast::Expr::Num(42)
    print("e1_eval=${e1.eval()}")
    print("e1_show=${show(e1)}")
    print("e1_depth=${depth(e1)}")

    // Negation
    let e2 = ast::Expr::Neg(ast::Expr::Num(7))
    print("e2_eval=${e2.eval()}")
    print("e2_show=${show(e2)}")

    // Addition
    let e3 = ast::Expr::Add(ast::Expr::Num(3), ast::Expr::Num(4))
    print("e3_eval=${e3.eval()}")
    print("e3_show=${show(e3)}")

    // Complex: (3 + 4) * (-(2))
    let e4 = ast::Expr::Mul(
        ast::Expr::Add(ast::Expr::Num(3), ast::Expr::Num(4)),
        ast::Expr::Neg(ast::Expr::Num(2))
    )
    print("e4_eval=${e4.eval()}")
    print("e4_show=${show(e4)}")
    print("e4_depth=${depth(e4)}")

    // Deep nesting: Neg(Neg(Neg(5)))
    let e5 = ast::Expr::Neg(ast::Expr::Neg(ast::Expr::Neg(ast::Expr::Num(5))))
    print("e5_eval=${e5.eval()}")
    print("e5_depth=${depth(e5)}")

    // Const access
    print("zero=${ast::ZERO_STR}")
}
