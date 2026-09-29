// Integer division-by-zero test — oracle-blind (JS returns Infinity; native
// should panic or trap).
//
// STATUS: The LLVM backend emits bare `sdiv` without a zero-check, so division
// by zero is currently LLVM undefined behaviour.  On x86-64 the hardware would
// trap, but LLVM is free to optimise the sdiv away.  This test documents the
// *desired* behaviour (non-zero exit / panic); it is marked EXPECT_PANIC so the
// harness asserts a non-zero exit code.  If the backend gains a divzero guard
// this test will start passing; until then the harness records it as a known
// failure.
//
// EXPECT_PANIC

fn get_zero() -> Int {
    let x = 1
    x - 1
}

fn main() {
    let a = 42
    let b = get_zero()
    let c = a / b
    print(c)
}
