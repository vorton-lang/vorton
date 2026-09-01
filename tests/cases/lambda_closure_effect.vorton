// Test: lambdas with closures — capture, nesting, HOF

fn main() {
    // Lambda capturing immutable outer variable
    let offset = 100
    let result = [1, 2, 3].map(fn(x) { x + offset })
    assert(result.get(0).unwrap_or(0) == 101, "capture in map lambda")
    assert(result.get(2).unwrap_or(0) == 103, "capture in map lambda 2")

    // Lambda with mutable capture via Cell
    let c = Cell(0)
    [1, 2, 3].map(fn(x) {
        c.set(c.get() + x)
        x
    })
    assert(c.get() == 6, "cell capture in map callback")

    // Lambda returning lambda
    let make_mult = fn(factor: Int) -> fn(Int) -> Int {
        fn(x: Int) -> Int { x * factor }
    }
    let times3 = make_mult(3)
    assert(times3(7) == 21, "lambda returning lambda")

    // Immediately invoked lambda
    let val = (fn(x: Int) -> Int { x * x })(5)
    assert(val == 25, "immediately invoked lambda")

    // Lambda as value in a let binding, then called
    let square = fn(x: Int) -> Int { x * x }
    assert(square(6) == 36, "lambda let binding")

    print("lambda_closure_effect: all tests passed")
}
