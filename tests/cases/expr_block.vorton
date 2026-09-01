// Test: block expressions in various positions

fn main() {
    // Block as function argument
    let result = {
        let a = 10
        let b = 20
        a + b
    }
    assert(result == 30, "block as value")

    // Block in if condition
    let x = if { let v = 5; v > 3 } { "yes" } else { "no" }
    assert(x == "yes", "block in if condition")

    // Block as match scrutinee
    let label = match { let n = 2 * 3; n } {
        6 => "six",
        _ => "other",
    }
    assert(label == "six", "block as match scrutinee")

    // Nested blocks
    let nested = {
        let outer = 10
        let inner = {
            let x = 20
            x + outer
        }
        inner * 2
    }
    assert(nested == 60, "nested blocks")

    // Block with let mut mutation
    let counted = {
        let mut c = 0
        c = c + 1
        c = c + 1
        c = c + 1
        c
    }
    assert(counted == 3, "block with var")

    print("expr_block: all tests passed")
}
