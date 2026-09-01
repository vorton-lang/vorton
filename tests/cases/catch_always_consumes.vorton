enum AppError {
    NotFound { key: Str },
    ParseError { msg: Str },
}

fn risky(x: Int) -> Int {
    if x < 0 { fail.raise(AppError::NotFound { key: "x" }) }
    if x == 0 { fail.raise(AppError::ParseError { msg: "zero" }) }
    x
}

// All enum variants matched but no wildcard — catch still consumes fail
fn safe_call(x: Int) -> Int {
    risky(x) catch {
        AppError::NotFound { key } => -1,
        AppError::ParseError { msg } => -2,
    }
}

fn main() {
    assert(safe_call(5) == 5, "success")
    assert(safe_call(-1) == -1, "not found caught")
    assert(safe_call(0) == -2, "parse error caught")
    print("catch_always_consumes: all tests passed")
}
