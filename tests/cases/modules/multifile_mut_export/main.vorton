use helper::{Counter, increment_val, add_to_val}

fn main() {
    // Test 1: mut self method from imported module
    let mut c = Counter { count: 0 }
    c.increment()
    assert(c.get() == 1, "mut self method from import should work")
    c.add(10)
    assert(c.get() == 11, "mut self method with param from import should work")

    // Test 2: mut value param function from imported module (auto-boxing)
    let mut x = 0
    increment_val(x)
    assert(x == 1, "mut param fn from import should work")
    add_to_val(x, 9)
    assert(x == 10, "mut param fn with extra arg from import should work")

    print("multifile_mut_export: all tests passed")
}
