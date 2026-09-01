// B-090: single custom effect with multiple ops, exercising the evidence-struct
// slot-order contract (effect_op_slot). Ops are PERFORMED in a different order
// than they are DECLARED, and the handler arms are written in yet another order —
// the result must still bind each perform to its own arm. Also covers:
//   - op parameters (add takes two ints, scale takes one)
//   - a handler arm that captures an outer-scope variable (`base`)
//   - return-value ops whose results feed back into the body
// Before B-090 the LLVM backend returned null for every op → wrong arithmetic /
// crash.

effect Calc {
    fn add(a: Int, b: Int) -> Int
    fn scale(x: Int) -> Int
    fn label() -> Str
}

fn compute() -> Str {
    let s = Calc.scale(10)          // declared 2nd, performed 1st
    let a = Calc.add(s, 5)          // declared 1st, performed 2nd
    let name = Calc.label()         // declared 3rd, performed 3rd
    "${name}=${a.to_str()}"
}

fn main() {
    let base = 3
    let r = handle {
        compute()
    } with {
        Calc.label() => "total",
        Calc.add(a, b) => a + b + base,   // captures outer `base`
        Calc.scale(x) => x * base,
    }
    print(r)                         // scale(10)=30, add(30,5)=30+5+3=38 → total=38
}
