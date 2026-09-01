enum MyError {
    NotFound,
    Invalid(Str),
}

fn risky() -> Int with {fail<MyError>} {
    fail.raise(MyError::NotFound)
}

fn main() {
    // Non-exhaustive catch -- should report E0601
    let result = risky() catch {
        MyError::NotFound => 0,
        // Missing MyError::Invalid branch
    }
}
