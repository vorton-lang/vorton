// B-100 P1.3 R2 adversarial combo: generic enum match + closure + RC.
//
// Pattern-matching on a generic enum (Option / custom Either) inside a
// function that also creates closures. The match extracts payload from
// the enum; the closure captures both the payload and possibly the enum
// itself. Perceus must correctly dup/drop both the enum and the closure
// environment.
//
// Exercises:
//   * Match on Option<T> inside a function that returns a closure
//   * Closure captures Option<T> match result
//   * Generic enum Either<L,R> — match + closure + trait dispatch
//   * Nested Option<Option<T>> matching with closures

enum Either<L, R> {
    Left(L),
    Right(R),
}

fn map_either<L, R, U>(e: Either<L, R>, f: fn(R) -> U, default: U) -> U {
    match e {
        Either::Left(_) => default,
        Either::Right(r) => f(r),
    }
}

fn option_or_else<T>(opt: Option<T>, f: fn() -> T) -> T {
    match opt {
        some(x) => x,
        none => f(),
    }
}

fn make_greeter(opt_name: Option<Str>) -> fn() -> Str {
    match opt_name {
        some(name) => fn() -> Str { "hello ${name}" },
        none => fn() -> Str { "hello stranger" },
    }
}

fn flatten_option<T>(opt: Option<Option<T>>) -> Option<T> {
    match opt {
        some(inner) => inner,
        none => none,
    }
}

fn main() {
    // Test 1: map_either — Right path with closure
    let e1: Either<Str, Int> = Either::Right(42)
    let r1 = map_either(e1, fn(x) { x * 2 }, -1)
    print("T1: ${r1}")

    // Test 2: map_either — Left path
    let e2: Either<Str, Int> = Either::Left("err")
    let r2 = map_either(e2, fn(x) { x * 2 }, -1)
    print("T2: ${r2}")

    // Test 3: map_either with Str transform
    let e3: Either<Int, Str> = Either::Right("world")
    let r3 = map_either(e3, fn(s) { "hello ${s}" }, "none")
    print("T3: ${r3}")

    // Test 4: option_or_else — Some path
    let o1: Option<Int> = some(10)
    let r4 = option_or_else(o1, fn() { 99 })
    print("T4: ${r4}")

    // Test 5: option_or_else — None path
    let o2: Option<Int> = none
    let r5 = option_or_else(o2, fn() { 99 })
    print("T5: ${r5}")

    // Test 6: make_greeter — Some name
    let g1 = make_greeter(some("Alice"))
    print("T6: ${g1()}")

    // Test 7: make_greeter — None
    let g2 = make_greeter(none)
    print("T7: ${g2()}")

    // Test 8: flatten_option — Some(Some(x))
    let nested1: Option<Option<Int>> = some(some(42))
    let r8 = flatten_option(nested1)
    match r8 {
        some(v) => print("T8: ${v}"),
        none => print("T8: none"),
    }

    // Test 9: flatten_option — Some(None)
    let nested2: Option<Option<Int>> = some(none)
    let r9 = flatten_option(nested2)
    match r9 {
        some(v) => print("T9: ${v}"),
        none => print("T9: none"),
    }

    // Test 10: flatten_option — None
    let nested3: Option<Option<Int>> = none
    let r10 = flatten_option(nested3)
    match r10 {
        some(v) => print("T10: ${v}"),
        none => print("T10: none"),
    }

    print("adversarial_combo_generic_enum_closure: done")
}
