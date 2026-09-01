// B-100 P1.3 R3 regression: Never unification in match with mixed arms.
//
// Round 2 fixed skip body-vs-return for Never. This test exercises the
// extreme case: match expressions where MOST arms return Never (via
// fail.raise) and only one arm returns a normal value. The checker must
// correctly unify the result type to the normal arm's type.
//
// Exercises:
//   * Match with 3 Never arms and 1 normal arm
//   * Match on enum where fail path is the common case
//   * Generic function with match where Never arms dominate
//   * if-else chain with multiple Never branches

enum Status {
    Ready(Int),
    Pending,
    Failed,
    Cancelled,
}

fn process_status(s: Status) -> Int with {fail<Str>} {
    match s {
        Status::Ready(v) => v,
        Status::Pending => fail.raise("pending"),
        Status::Failed => fail.raise("failed"),
        Status::Cancelled => fail.raise("cancelled"),
    }
}

fn classify(x: Int) -> Str with {fail<Str>} {
    if x < 0 {
        fail.raise("negative")
    } else if x == 0 {
        fail.raise("zero")
    } else if x > 100 {
        fail.raise("too large")
    } else {
        "ok(${x})"
    }
}

enum Input<T> {
    Valid(T),
    Empty,
    Invalid(Str),
}

fn extract<T: Eq>(input: Input<T>, fallback: T) -> T with {fail<Str>} {
    match input {
        Input::Valid(v) => v,
        Input::Empty => fail.raise("empty input"),
        Input::Invalid(msg) => fail.raise("invalid: ${msg}"),
    }
}

fn main() {
    // Test 1: match with 3 Never + 1 normal — Ready
    let r1 = process_status(Status::Ready(42)) catch { e => -1 }
    print("T1: ${r1}")

    // Test 2: match — Pending (Never path)
    let r2 = process_status(Status::Pending) catch { e => -1 }
    print("T2: ${r2}")

    // Test 3: match — Failed (Never path)
    let r3 = process_status(Status::Failed) catch { e => -3 }
    print("T3: ${r3}")

    // Test 4: match — Cancelled (Never path)
    let r4 = process_status(Status::Cancelled) catch { e => -4 }
    print("T4: ${r4}")

    // Test 5: if-else with multiple Never branches — success
    let r5 = classify(50) catch { e => "err: ${e}" }
    print("T5: ${r5}")

    // Test 6: if-else — negative (Never)
    let r6 = classify(-5) catch { e => "err: ${e}" }
    print("T6: ${r6}")

    // Test 7: if-else — zero (Never)
    let r7 = classify(0) catch { e => "err: ${e}" }
    print("T7: ${r7}")

    // Test 8: if-else — too large (Never)
    let r8 = classify(200) catch { e => "err: ${e}" }
    print("T8: ${r8}")

    // Test 9: generic extract — Valid
    let r9 = extract(Input::Valid(10), 0) catch { e => -1 }
    print("T9: ${r9}")

    // Test 10: generic extract — Empty (Never)
    let r10 = extract(Input::Empty, 0) catch { e => -1 }
    print("T10: ${r10}")

    // Test 11: generic extract — Invalid (Never)
    let r11 = extract(Input::Invalid("bad data"), "default") catch { e => "err" }
    print("T11: ${r11}")

    // Test 12: generic extract — Valid with Str
    let r12 = extract(Input::Valid("hello"), "none") catch { e => "err" }
    print("T12: ${r12}")

    print("adversarial_regress_never_match_arms: done")
}
