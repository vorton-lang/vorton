fn main() {
    let a: Int? = none
    let b: Int? = none

    // nested tuple pattern with bare enum variants
    let result = match (a, b) {
        (some(x), some(y)) => x + y,
        (some(x), none) => x,
        (none, some(y)) => y,
        (none, none) => 0,
    }
    assert(result == 0, "both none should give 0")

    let c: Int? = some(3)
    let d: Int? = some(4)
    let result2 = match (c, d) {
        (some(x), some(y)) => x + y,
        (some(x), none) => x,
        (none, some(y)) => y,
        (none, none) => 0,
    }
    assert(result2 == 7, "both some should give 7")

    print("pass: match tuple bare variant")
}
