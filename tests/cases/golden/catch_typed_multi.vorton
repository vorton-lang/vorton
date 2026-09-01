// B-100 P1.1: multi-arm + typed catch — catch blocks with multiple pattern
// arms matching different enum variants. Tests that catch dispatch, pattern
// matching, and value extraction work correctly.

enum AppError {
    NotFound { key: Str },
    Invalid { code: Int },
    Timeout,
}

fn lookup(key: Str) -> Str {
    if key == "" { fail.raise(AppError::NotFound { key: "empty" }) }
    if key == "bad" { fail.raise(AppError::Invalid { code: 42 }) }
    if key == "slow" { fail.raise(AppError::Timeout) }
    "value-${key}"
}

fn nested_lookup(key: Str) -> Str {
    let inner = lookup(key)
    "wrapped(${inner})"
}

fn main() {
    // Test 1: success path
    let r1 = lookup("ok") catch {
        AppError::NotFound { key } => "nf:${key}",
        AppError::Invalid { code } => "inv:${code.to_str()}",
        AppError::Timeout => "timeout",
    }
    print("T1: ${r1}")

    // Test 2: NotFound arm
    let r2 = lookup("") catch {
        AppError::NotFound { key } => "nf:${key}",
        AppError::Invalid { code } => "inv:${code.to_str()}",
        AppError::Timeout => "timeout",
    }
    print("T2: ${r2}")

    // Test 3: Invalid arm
    let r3 = lookup("bad") catch {
        AppError::NotFound { key } => "nf:${key}",
        AppError::Invalid { code } => "inv:${code.to_str()}",
        AppError::Timeout => "timeout",
    }
    print("T3: ${r3}")

    // Test 4: Timeout arm (unit variant)
    let r4 = lookup("slow") catch {
        AppError::NotFound { key } => "nf:${key}",
        AppError::Invalid { code } => "inv:${code.to_str()}",
        AppError::Timeout => "timeout",
    }
    print("T4: ${r4}")

    // Test 5: wildcard catch
    let r5 = lookup("") catch { _ => "caught-all" }
    print("T5: ${r5}")

    // Test 6: catch on nested call — effect propagates through
    let r6 = nested_lookup("bad") catch {
        AppError::NotFound { key } => "nf",
        AppError::Invalid { code } => "inv:${code.to_str()}",
        AppError::Timeout => "timeout",
    }
    print("T6: ${r6}")

    // Test 7: catch value used in further computation
    let r7 = lookup("slow") catch {
        AppError::NotFound { key } => "nf",
        AppError::Invalid { code } => "inv",
        AppError::Timeout => "timeout-caught",
    }
    print("T7: ${r7}")

    print("catch_typed_multi: done")
}
