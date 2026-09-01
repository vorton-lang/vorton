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
    let r2 = do_work(0) catch {
        AppError::NotFound { key } => -1,
        AppError::Invalid { msg } => -2,
        AppError::Timeout => -3,
    }
    print("r2=${r2}")
}
