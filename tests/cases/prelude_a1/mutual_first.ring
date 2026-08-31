pub fn prelude_a1_right(f: fn(Int) -> Int, value: Int, n: Int) -> Int {
    if n == 0 { value } else { prelude_a1_left(f, f(value), n - 1) }
}

pub fn prelude_a1_left(f: fn(Int) -> Int, value: Int, n: Int) -> Int {
    if n == 0 { value } else { prelude_a1_right(f, f(value), n - 1) }
}

pub fn prelude_a1_self<T>(f: fn(T) -> T, value: T, n: Int) -> T {
    if n == 0 { value } else { prelude_a1_self(f, f(value), n - 1) }
}
