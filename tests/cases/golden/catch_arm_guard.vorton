// #206 regression: catch arm guards must be evaluated in LLVM backend.
// Diff test: output must match golden .expected file.
// NOTE: guards referencing catch-bound variables (e.g. `x if x > 10`)
// have a known binding-order issue — tracked separately.
// Tests use outer variables in guards to avoid that bug.

fn risky(n: Int) -> Str {
    fail.raise(n)
}

fn test_guard_basic() {
    let threshold = 42
    let result = risky(10) catch {
        _ if threshold > 100 => "big",
        _ if threshold > 10 => "medium",
        _ => "small",
    }
    print("basic: ${result}")
}

fn test_guard_first() {
    let threshold = 200
    let result = risky(10) catch {
        _ if threshold > 100 => "big",
        _ if threshold > 10 => "medium",
        _ => "small",
    }
    print("first: ${result}")
}

fn test_guard_fallthrough() {
    let threshold = 3
    let result = risky(10) catch {
        _ if threshold > 100 => "big",
        _ if threshold > 10 => "medium",
        _ => "small",
    }
    print("fallthrough: ${result}")
}

fn test_guard_with_binding() {
    let flag = true
    let result = risky(99) catch {
        x if flag => x.to_str(),
        _ => "fallback",
    }
    print("binding: ${result}")
}

fn test_guard_false_binding() {
    let flag = false
    let result = risky(99) catch {
        x if flag => x.to_str(),
        _ => "fallback",
    }
    print("false-binding: ${result}")
}

fn main() {
    test_guard_basic()
    test_guard_first()
    test_guard_fallthrough()
    test_guard_with_binding()
    test_guard_false_binding()
    print("catch_arm_guard: done")
}
