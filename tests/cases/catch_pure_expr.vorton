// Test: catch on pure expression emits warning but compiles successfully
// The handler is dead code since 42 has no fail effect

fn main() {
    let x = 42 catch { e => 0 }
    assert(x == 42, "catch on pure should return body value")
    print("pass: catch on pure warning")
}
