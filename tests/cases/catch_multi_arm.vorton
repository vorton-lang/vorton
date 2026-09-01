enum AppError {
    NotFound { key: Str },
    Invalid { msg: Str },
    Timeout,
}

fn do_work(x: Int) -> Int {
    if x == 0 { fail.raise(AppError::Timeout) }
    if x < 0 { fail.raise(AppError::Invalid { msg: "negative" }) }
    if x > 100 { fail.raise(AppError::NotFound { key: "big" }) }
    x * 2
}

fn main() {
    let r1 = do_work(5) catch {
        AppError::NotFound { key } => -1,
        AppError::Invalid { msg } => -2,
        AppError::Timeout => -3,
    }
    assert(r1 == 10, "success case")

    let r2 = do_work(0) catch {
        AppError::NotFound { key } => -1,
        AppError::Invalid { msg } => -2,
        AppError::Timeout => -3,
    }
    assert(r2 == -3, "timeout case")

    let r3 = do_work(-1) catch {
        _ => -99,
    }
    assert(r3 == -99, "wildcard catch")

    print("catch_multi_arm: all tests passed")
}
