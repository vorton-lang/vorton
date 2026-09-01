// #206 regression: catch arm guards must be evaluated.
// #207 regression: guards referencing catch-bound variables must work
// (bindings emitted before guard eval).

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
    assert(result == "medium", "threshold=42 should be medium, got ${result}")
}

fn test_guard_first() {
    let threshold = 200
    let result = risky(10) catch {
        _ if threshold > 100 => "big",
        _ if threshold > 10 => "medium",
        _ => "small",
    }
    assert(result == "big", "threshold=200 should be big, got ${result}")
}

fn test_guard_fallthrough() {
    let threshold = 3
    let result = risky(10) catch {
        _ if threshold > 100 => "big",
        _ if threshold > 10 => "medium",
        _ => "small",
    }
    assert(result == "small", "threshold=3 should be small, got ${result}")
}

fn test_guard_with_binding() {
    // Guard uses outer variable, binding captures the error value
    let flag = true
    let result = risky(99) catch {
        x if flag => x.to_str(),
        _ => "fallback",
    }
    assert(result == "99", "flag=true should give '99', got ${result}")
}

fn test_guard_false_binding() {
    let flag = false
    let result = risky(99) catch {
        x if flag => x.to_str(),
        _ => "fallback",
    }
    assert(result == "fallback", "flag=false should give 'fallback', got ${result}")
}

// #207: guard directly references the catch-bound pattern variable
fn test_guard_uses_bound_var() {
    let result = risky(50) catch {
        x if x > 100 => "big",
        x if x > 10 => "medium: ${x.to_str()}",
        _ => "small",
    }
    assert(result == "medium: 50", "x=50 should be medium, got ${result}")
}

fn test_guard_uses_bound_var_first() {
    let result = risky(200) catch {
        x if x > 100 => "big: ${x.to_str()}",
        x if x > 10 => "medium",
        _ => "small",
    }
    assert(result == "big: 200", "x=200 should be big, got ${result}")
}

fn test_guard_uses_bound_var_fallthrough() {
    let result = risky(5) catch {
        x if x > 100 => "big",
        x if x > 10 => "medium",
        _ => "small",
    }
    assert(result == "small", "x=5 should be small, got ${result}")
}

fn main() {
    test_guard_basic()
    test_guard_first()
    test_guard_fallthrough()
    test_guard_with_binding()
    test_guard_false_binding()
    test_guard_uses_bound_var()
    test_guard_uses_bound_var_first()
    test_guard_uses_bound_var_fallthrough()
    print("catch_arm_guard: all tests passed")
}
