// Test: generic enum with type inference at call sites

enum Either<L, R> {
    Left(L),
    Right(R),
}

fn map_right<L, R, U>(e: Either<L, R>, f: fn(R) -> U) -> Either<L, U> {
    match e {
        Left(l) => Left(l),
        Right(r) => Right(f(r)),
    }
}

fn get_right_or<R>(e: Either<Str, R>, default: R) -> R {
    match e {
        Left(msg) => default,
        Right(v) => v,
    }
}

fn main() {
    let a = Left("error")
    let b = Right(42)

    // map_right on Left (no change)
    let a2 = map_right(a, fn(x: Int) -> Int { x * 2 })
    match a2 {
        Left(s) => assert(s == "error", "left preserved"),
        Right(v) => assert(false, "should be left"),
    }

    // map_right on Right (transforms value)
    let b2 = map_right(b, fn(x) { x * 2 })
    match b2 {
        Left(s) => assert(false, "should be right"),
        Right(v) => assert(v == 84, "right mapped"),
    }

    // get_right_or
    assert(get_right_or(Left("err"), 0) == 0, "left default")
    assert(get_right_or(Right(99), 0) == 99, "right value")

    print("generic_enum: all tests passed")
}
