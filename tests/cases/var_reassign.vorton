// Test: let mut reassignment in different contexts

struct Point { x: Int, y: Int }

fn main() {
    // Basic let mut reassignment
    let mut x = 1
    x = 2
    assert(x == 2, "basic reassign")

    // Compound assignment operators
    let mut n = 10
    n += 5
    assert(n == 15, "+=")
    n -= 3
    assert(n == 12, "-=")

    // Reassignment with expression
    let mut m = 5
    m = m * 2 + 1
    assert(m == 11, "expr reassign")

    // let mut struct field mutation
    let mut p = Point { x: 1, y: 2 }
    p.x = 10
    assert(p.x == 10, "struct field assign")
    p.y = 20
    assert(p.y == 20, "struct field assign 2")

    // let mut in while loop
    let mut sum = 0
    let mut i = 1
    while i <= 5 {
        sum += i
        i += 1
    }
    assert(sum == 15, "let mut in while")

    // let mut in for loop
    let mut total = 0
    for j in 0..5 {
        total += j * 2
    }
    assert(total == 20, "let mut in for")

    print("var_reassign: all tests passed")
}
