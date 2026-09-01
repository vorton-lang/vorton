// B-100 P1.1 parity: recursive functions — factorial, fibonacci, recursive
// with Option, recursive accumulator.

fn factorial(n: Int) -> Int {
    if n <= 1 { 1 }
    else { n * factorial(n - 1) }
}

fn fib(n: Int) -> Int {
    if n <= 1 { n }
    else { fib(n - 1) + fib(n - 2) }
}

fn find_first_positive(xs: List<Int>) -> Option<Int> {
    if xs.is_empty() { return none }
    let first = xs.get(0)
    match first {
        some(v) => {
            if v > 0 { some(v) }
            else { find_first_positive(xs.slice(1, xs.len())) }
        },
        none => none,
    }
}

fn sum_list(xs: List<Int>, acc: Int) -> Int {
    if xs.is_empty() { acc }
    else {
        let head = xs.get(0).unwrap_or(0)
        sum_list(xs.slice(1, xs.len()), acc + head)
    }
}

fn main() {
    // Factorial
    print("fact5=${factorial(5)}")
    print("fact1=${factorial(1)}")
    print("fact0=${factorial(0)}")

    // Fibonacci
    print("fib0=${fib(0)}")
    print("fib1=${fib(1)}")
    print("fib6=${fib(6)}")
    print("fib10=${fib(10)}")

    // Recursive with Option
    let xs = [-3, -1, 0, 5, 2]
    let r = find_first_positive(xs)
    print("pos=${r.unwrap_or(-999)}")

    let all_neg = [-1, -2, -3]
    let nr = find_first_positive(all_neg)
    print("none=${nr.is_none()}")

    // Recursive accumulator
    print("sum=${sum_list([1, 2, 3, 4, 5], 0)}")
}
