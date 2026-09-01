// Regression test for B-077: cross-module pub const references must not
// get spurious .value suffix from auto-boxing.
//
// The bug: each module starts def_id allocation from 0, so a cross-module
// const's def_id can collide with a local let-mut variable's def_id in
// boxed_vars, causing codegen to emit `consts$GREETING.value` instead of
// `consts$GREETING`.

use consts::{GREETING, CODE_A, CODE_B, THRESHOLD}

fn main() {
    // Use several let mut variables to generate local def_ids that may
    // collide with the imported const def_ids.
    let mut a = 0
    let mut b = 0
    let mut c = 0
    let mut d = 0

    // Capture mut vars in a closure to trigger auto-boxing
    let inc = fn() {
        a = a + 1
        b = b + 1
        c = c + 1
        d = d + 1
    }
    inc()
    inc()

    // Now reference cross-module consts -- these must NOT get .value suffix
    assert(GREETING == "hello", "cross-module const GREETING failed")
    assert(CODE_A == "A001", "cross-module const CODE_A failed")
    assert(CODE_B == "B002", "cross-module const CODE_B failed")
    assert(THRESHOLD == 42, "cross-module const THRESHOLD failed")

    // Verify the mut vars still work correctly (boxing is intact)
    assert(a == 2, "boxed mut a should be 2")
    assert(b == 2, "boxed mut b should be 2")
    assert(c == 2, "boxed mut c should be 2")
    assert(d == 2, "boxed mut d should be 2")

    print("cross_module_const: all tests passed")
}
