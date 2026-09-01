// B-100 P1.1: mut effect system — mut parameter value-type writeback.
// Tests that mut parameter reassignment is visible to the caller, and that
// mut interacts correctly with other language features. Verifies parity
// for mut cell mechanics.

fn increment(mut x: Int) {
    x = x + 1
}

fn add_to(mut x: Int, n: Int) {
    x = x + n
}

fn swap_values(mut a: Int, mut b: Int) {
    let tmp = a
    a = b
    b = tmp
}

fn conditional_mut(mut x: Int, flag: Bool) {
    if flag {
        x = x * 10
    } else {
        x = x + 1
    }
}

fn chain_mut(mut x: Int) {
    x = x + 1
    x = x * 2
    x = x - 3
}

fn mut_in_loop(mut x: Int, n: Int) {
    let mut i = 0
    while i < n {
        x = x + 1
        i = i + 1
    }
}

fn main() {
    // Test 1: basic mut writeback
    let mut a = 10
    increment(a)
    print("T1: ${a.to_str()}")

    // Test 2: mut with extra parameter
    let mut b = 5
    add_to(b, 20)
    print("T2: ${b.to_str()}")

    // Test 3: two mut params (swap)
    let mut x = 1
    let mut y = 2
    swap_values(x, y)
    print("T3: ${x.to_str()} ${y.to_str()}")

    // Test 4: conditional mut — true branch
    let mut c = 3
    conditional_mut(c, true)
    print("T4a: ${c.to_str()}")

    // Test 5: conditional mut — false branch
    let mut d = 3
    conditional_mut(d, false)
    print("T4b: ${d.to_str()}")

    // Test 6: chained mutations
    let mut e = 5
    chain_mut(e)
    print("T5: ${e.to_str()}")

    // Test 7: mut in loop
    let mut f = 0
    mut_in_loop(f, 5)
    print("T6: ${f.to_str()}")

    // Test 8: multiple calls to same mut function
    let mut g = 0
    increment(g)
    increment(g)
    increment(g)
    print("T7: ${g.to_str()}")

    print("mut_effect_basic: done")
}
