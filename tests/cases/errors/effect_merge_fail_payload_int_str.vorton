// expect-error: E0301
// Reverse the branch order and annotation from the companion regression.
// Acceptance must not depend on which fail payload row_merge sees first.

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("text")
}

fn branch_fail(flag: Bool) -> Int with {fail<Int>} {
    if flag {
        raise_number()
    } else {
        raise_text()
    }
}

fn main() {
    let result = branch_fail(true) catch { _ => 0 }
    print(result.to_str())
}
