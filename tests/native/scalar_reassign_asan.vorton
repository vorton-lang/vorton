// B-104 W4 ASan probe — exercise every scalar-reassign drop path that could UAF:
//  - plain counter `i = i + 1` (self-read RHS, old box freed each step)
//  - shared scalar `let y = x` then reassign x (y dup'd → old box rc 2→1, y stays valid)
//  - Bool reassign, Float reassign
// ASan must report ZERO errors (no double-free / use-after-free).
fn main() {
    let mut i = 0
    let mut sum = 0
    while i < 1000 {
        sum = sum + i
        i = i + 1
    }
    // shared scalar: y holds a dup of x's box; reassigning x must NOT free y's value
    let mut x = 42
    let y = x
    x = x + 100
    let z = y
    // bool + float reassignment
    let mut b = true
    b = false
    let mut f = 1.5
    f = f + 2.5
    print(sum)
    print(x)
    print(y)
    print(z)
    print(b)
    print(f)
}
