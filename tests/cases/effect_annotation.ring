effect custom_effect {
    fn get_value() -> Int
}

// 1. Function with io effect annotation
fn greet(name: Str) -> Unit with {console} {
    print("Hello, ${name}")
}

// 2. Function with fail effect annotation
fn safe_divide(a: Int, b: Int) -> Int with {fail<Str>} {
    if b == 0 { fail.raise("division by zero") }
    a / b
}

// 3. Function without annotation (backward compatible)
fn add(a: Int, b: Int) -> Int {
    a + b
}

// 4. Annotation is upper bound (actual effects can be subset)
fn might_print(x: Int) -> Int with {console} {
    // Does not actually use io, but declares it — legal
    x + 1
}

fn main() {
    greet("Ring")
    let result = safe_divide(10, 2) catch { _ => 0 }
    print(result)
    print(add(1, 2))
    print(might_print(5))
}
