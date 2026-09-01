// Guard combined with an OR-pattern over enum variants. The guard applies to
// the whole OR-alternative set; a false guard falls through to the next arm.
enum Op { Add, Sub, Mul, Div }

fn eval(op: Op, a: Int, b: Int) -> Str {
    match op {
        Op::Add | Op::Sub if a == 0 => "additive with zero lhs",
        Op::Add => "sum=${a + b}",
        Op::Sub => "diff=${a - b}",
        Op::Mul | Op::Div if b == 0 => "mul/div guarded",
        Op::Mul => "prod=${a * b}",
        Op::Div => "quot=${a / b}"
    }
}

fn main() {
    print(eval(Op::Add, 0, 5))   // additive with zero lhs
    print(eval(Op::Sub, 0, 5))   // additive with zero lhs
    print(eval(Op::Add, 3, 5))   // sum=8
    print(eval(Op::Sub, 9, 4))   // diff=5
    print(eval(Op::Mul, 2, 0))   // mul/div guarded
    print(eval(Op::Div, 2, 0))   // mul/div guarded
    print(eval(Op::Mul, 3, 4))   // prod=12
    print(eval(Op::Div, 12, 3))  // quot=4
}
