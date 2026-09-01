// Test: Enum named fields with generics

enum LocalResult<T, E> {
    Ok { value: T },
    Err { message: E },
}

fn unwrap_or<T, E>(r: LocalResult<T, E>, default: T) -> T {
    match r {
        Ok { value } => value,
        Err { .. } => default,
    }
}

fn main() {
    let ok = Ok { value: 42 }
    let err = Err { message: "bad" }

    assert(unwrap_or(ok, 0) == 42, "unwrap ok")
    assert(unwrap_or(err, 0) == 0, "unwrap err")

    // Mixed positional and named in same enum
    print("enum_named_fields_generic: all tests passed")
}
