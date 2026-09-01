enum Op { Add, Sub, Eq, Neq, Lt }

fn kind(o: Op) -> Str {
    match o {
        Op::Add => "arith",
        Op::Sub => "arith",
        Op::Eq | Op::Neq => "compare-eq",
        Op::Lt => "compare-ord"
    }
}

fn main() {
    print(kind(Op::Add))   // arith
    print(kind(Op::Eq))    // compare-eq
    print(kind(Op::Neq))   // compare-eq
    print(kind(Op::Lt))    // compare-ord
}
