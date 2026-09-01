// Test: fail effect with catch (catch default), combining with Option

fn divide(a: Int, b: Int) -> Int {
    if b == 0 {
        fail.raise("division by zero")
    }
    a / b
}

fn safe_divide(a: Int, b: Int) -> Int {
    divide(a, b) catch { _ => -1 }
}

fn main() {
    // catch catches fail effect
    assert(safe_divide(10, 2) == 5, "safe div success")
    assert(safe_divide(10, 0) == -1, "safe div catch")

    // unwrap_or with option
    let x: Int? = some(42)
    let y: Int? = none
    assert(x.unwrap_or(0) == 42, "option unwrap_or some")
    assert(y.unwrap_or(0) == 0, "option unwrap_or none")

    // some()+catch replaces try
    let r1 = some(divide(10, 2)) catch { _ => none }
    assert(r1.unwrap_or(-1) == 5, "try success")
    let r2 = some(divide(10, 0)) catch { _ => none }
    assert(r2.is_none(), "try fail becomes none")

    print("effect_fail_or: all tests passed")
}
