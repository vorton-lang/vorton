enum MyError {
    NotFound,
    Invalid(Str),
}

fn risky() -> Int with {fail<MyError>} {
    fail.raise(MyError::NotFound)
}

fn main() {
    // Exhaustive catch -- should compile
    let result = risky() catch {
        MyError::NotFound => 0,
        MyError::Invalid(msg) => -1,
    }
    assert(result == 0, "catch exhaustive")

    // Wildcard catch -- should compile
    let result2 = risky() catch {
        _ => -99,
    }
    assert(result2 == -99, "catch wildcard")

    // Binding catch -- should compile
    let result3 = risky() catch {
        e => -1,
    }
    assert(result3 == -1, "catch binding")

    print("catch exhaustive tests passed")
}
