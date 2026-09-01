// Integer modulo-by-zero test — oracle-blind (JS returns NaN; native
// should panic or trap).
//
// B-148: The LLVM backend emits a divzero guard before `srem`, so modulo
// by zero panics with "integer division by zero".
//
// EXPECT_PANIC

fn get_zero() -> Int {
    let x = 1
    x - 1
}

fn main() {
    let a = 42
    let b = get_zero()
    let c = a % b
    print(c)
}
