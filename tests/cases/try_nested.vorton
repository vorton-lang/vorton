fn risky(x: Int) -> Int {
    if x > 0 { x + 1 } else { fail.raise("zero") }
}

fn main() {
    // Nested: outer catch wraps inner fail-to-option + to_fail
    let result = some(
        (some(risky(0)) catch { _ => none }).to_fail("inner failed")
    ) catch { _ => none }
    let v1 = match result { some(v) => v, none => -1 }
    print(v1)

    let result2 = some(
        (some(risky(5)) catch { _ => none }).to_fail("inner failed")
    ) catch { _ => none }
    let v2 = match result2 { some(v) => v, none => -1 }
    print(v2)
}
