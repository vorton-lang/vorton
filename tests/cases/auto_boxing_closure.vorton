fn main() {
    let mut counter = 0
    let inc = fn() { counter = counter + 1 }
    inc()
    inc()
    inc()
    assert(counter == 3, "closure capture boxing")

    let mut x = 10
    let f = fn() {
        let g = fn() { x = x + 1 }
        g()
        g()
    }
    f()
    assert(x == 12, "nested closure capture")

    let mut shared = 0
    let add1 = fn() { shared = shared + 1 }
    let add2 = fn() { shared = shared + 2 }
    add1()
    add2()
    assert(shared == 3, "multiple closures share box")

    print("auto_boxing_closure: all tests passed")
}
