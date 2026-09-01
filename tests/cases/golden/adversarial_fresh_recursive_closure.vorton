// B-100 P1.3 R3 adversarial: recursion + closures — recursive functions that
// create or receive closures, testing RC interaction with captured environments
// across recursive call stacks.
//
// Exercises:
//   * Recursive function that passes a closure down the stack
//   * Recursive function that returns a closure
//   * Closure capturing a recursive-call result
//   * Fibonacci with memoization-like pattern (accumulator closures)

// Apply a transform at each level of recursion, accumulating via closure
fn repeat_transform(n: Int, value: Str, f: fn(Str) -> Str) -> Str {
    if n <= 0 { value } else { repeat_transform(n - 1, f(value), f) }
}

// Recursive countdown that builds a closure chain
fn make_adder(n: Int) -> fn(Int) -> Int {
    if n <= 0 {
        fn(x) { x }
    } else {
        let inner = make_adder(n - 1)
        fn(x) { inner(x) + 1 }
    }
}

// Recursive function that uses a predicate closure
fn count_matching(xs: List<Int>, pred: fn(Int) -> Bool) -> Int {
    if xs.len() == 0 {
        0
    } else {
        let first = xs[0]
        let rest = xs.slice(1, xs.len())
        let match_val = if pred(first) { 1 } else { 0 }
        match_val + count_matching(rest, pred)
    }
}

// Recursive Fibonacci with tail-call style (accumulator pair)
fn fib_acc(n: Int, a: Int, b: Int) -> Int {
    if n <= 0 { a } else { fib_acc(n - 1, b, a + b) }
}

fn fib(n: Int) -> Int {
    fib_acc(n, 0, 1)
}

fn main() {
    // Test 1: repeat_transform — wrap string in parens n times
    let r1 = repeat_transform(3, "x", fn(s) { "(${s})" })
    print("wrap3=${r1}")

    // Test 2: repeat_transform with 0 iterations
    let r2 = repeat_transform(0, "hello", fn(s) { "(${s})" })
    print("wrap0=${r2}")

    // Test 3: make_adder — chain of closures
    let add3 = make_adder(3)
    print("add3(10)=${add3(10)}")
    let add0 = make_adder(0)
    print("add0(5)=${add0(5)}")
    let add5 = make_adder(5)
    print("add5(0)=${add5(0)}")

    // Test 4: count_matching with closure predicate
    let nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    let evens = count_matching(nums, fn(x) { x % 2 == 0 })
    print("evens=${evens}")
    let big = count_matching(nums, fn(x) { x > 7 })
    print("big=${big}")

    // Test 5: Fibonacci
    print("fib0=${fib(0)}")
    print("fib1=${fib(1)}")
    print("fib5=${fib(5)}")
    print("fib10=${fib(10)}")
}
