// Test: single-variant enum — edge case for exhaustiveness and codegen

enum Wrapper {
    Value(Int),
}

enum Named {
    Entry { key: Str, val: Int },
}

fn unwrap(w: Wrapper) -> Int {
    match w {
        Value(n) => n,
    }
}

fn get_key(e: Named) -> Str {
    match e {
        Entry { key, val } => key,
    }
}

fn main() {
    let w = Value(42)
    assert(unwrap(w) == 42, "single variant unwrap")

    let e = Entry { key: "x", val: 10 }
    assert(get_key(e) == "x", "single named variant")

    // Match with wildcard (redundant but should work)
    let result = match w {
        Value(n) => n * 2,
    }
    assert(result == 84, "single variant match expr")

    print("enum_single_variant: all tests passed")
}
