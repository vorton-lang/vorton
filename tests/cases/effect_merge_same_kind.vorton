// Test: row_merge unifies type params for same-kind effects
// Previously, fail<Str> and fail<Int> would both appear in merged row
// because effects_same_kind required types_equal for fail.
// After fix, effects_match_kind is used so same-kind effects are
// deduplicated, and their type params are unified.

// A function that may fail with a string error
fn fail_str() -> Int with {fail<Str>} {
    42
}

// A function that catches the fail and produces a value
fn safe_caller() -> Int {
    let result = fail_str() catch {
        e => 0
    }
    result
}

// Test: two branches with same fail type should merge cleanly
fn branch_fail(cond: Bool) -> Int with {fail<Str>} {
    if cond {
        fail_str()
    } else {
        fail_str()
    }
}

// A shared type variable is also a valid single payload. The hard agreement
// check must preserve genericity instead of rejecting or monomorphizing it.
fn fail_value<T>(value: T) -> Int with {fail<T>} {
    fail.raise(value)
}

fn branch_fail_generic<T>(cond: Bool, value: T) -> Int with {fail<T>} {
    if cond {
        fail_value(value)
    } else {
        fail_value(value)
    }
}

fn main() {
    let x = safe_caller()
    assert(x == 42, "safe_caller should return 42")

    let y = branch_fail(true) catch { e => -1 }
    assert(y == 42, "branch_fail true should return 42")

    let z = branch_fail(false) catch { e => -1 }
    assert(z == 42, "branch_fail false should return 42")

    let generic_text = branch_fail_generic(true, "generic") catch { _ => 7 }
    let generic_number = branch_fail_generic(false, 9) catch { _ => 10 }
    assert(generic_text == 7, "shared generic fail<Str> payload")
    assert(generic_number == 10, "shared generic fail<Int> payload")

    print("effect merge same kind: ok")
}
