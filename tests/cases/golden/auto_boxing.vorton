// B-100 P1.1: auto-boxing parity — Int through generic function (heap boxing),
// closure capture of mut variable (cell boxing), and nested closure auto-boxing.

fn identity<T>(x: T) -> T with {} { x }

fn apply<T>(f: fn(T) -> T, x: T) -> T { f(x) }

fn wrap_and_unwrap<T>(x: T) -> T {
    let y = x
    y
}

fn main() {
    // Int passed to generic fn (auto-boxed to heap in LLVM)
    print(identity(42))
    print(identity("hello"))
    print(identity(true))

    // generic fn applied through higher-order fn
    print(apply(identity, 99))
    print(apply(identity, "world"))

    // nested generic wrapping
    print(wrap_and_unwrap(7))
    print(wrap_and_unwrap("abc"))

    // closure capture of mut variable (cell boxing)
    let mut counter = 0
    let inc = fn() { counter = counter + 1 }
    inc()
    inc()
    inc()
    print(counter)

    // nested closure capture (both levels share the box)
    let mut x = 10
    let f = fn() {
        let g = fn() { x = x + 1 }
        g()
        g()
    }
    f()
    print(x)

    // multiple closures sharing a mut box
    let mut shared = 0
    let add1 = fn() { shared = shared + 1 }
    let add2 = fn() { shared = shared + 2 }
    add1()
    add2()
    add1()
    print(shared)

    // closure capture of non-mut variable in generic context
    let val = 100
    let get_val = fn() -> Int { val }
    print(identity(get_val()))
}
