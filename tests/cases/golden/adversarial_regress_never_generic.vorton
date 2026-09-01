// B-100 P1.3 R3 regression: Never type unification in generic contexts.
//
// Round 2 fixed skip body-vs-return for Never type. This test pushes the
// fix with:
//   * Generic fn where match has some arms that fail.raise (Never)
//   * if-else where one branch returns Never via fail
//   * Generic + effect + multiple catch combinations
//   * match with multiple Never arms and one normal arm

enum ParseErr { BadFormat, OutOfRange }

fn parse_positive<T: Eq>(xs: List<T>, target: T) -> T with {fail<ParseErr>} {
    // match-like: some paths fail, some return
    for x in xs {
        if x == target { return x }
    }
    fail.raise(ParseErr::BadFormat)
}

fn require_nonempty(s: Str) -> Str with {fail<Str>} {
    if s == "" {
        fail.raise("empty string")
    } else {
        s
    }
}

fn safe_divide(a: Int, b: Int) -> Int with {fail<Str>} {
    if b == 0 {
        fail.raise("division by zero")
    } else {
        a / b
    }
}

fn chain_validate(x: Int) -> Str with {fail<Str>} {
    // Multiple potential Never points
    let name = require_nonempty("test")
    let result = safe_divide(x, 2)
    "${name}=${result}"
}

fn main() {
    // Test 1: generic fn with fail — success path
    let r1 = parse_positive([1, 2, 3], 2) catch {
        ParseErr::BadFormat => -1,
        ParseErr::OutOfRange => -2,
    }
    print("T1: ${r1}")

    // Test 2: generic fn with fail — failure path
    let r2 = parse_positive([1, 2, 3], 99) catch {
        ParseErr::BadFormat => -1,
        ParseErr::OutOfRange => -2,
    }
    print("T2: ${r2}")

    // Test 3: generic fn with fail + Str type
    let r3 = parse_positive(["a", "b", "c"], "b") catch {
        ParseErr::BadFormat => "none",
        ParseErr::OutOfRange => "range",
    }
    print("T3: ${r3}")

    // Test 4: if-else with one Never branch — success
    let r4 = require_nonempty("hello") catch { e => "err: ${e}" }
    print("T4: ${r4}")

    // Test 5: if-else with one Never branch — failure
    let r5 = require_nonempty("") catch { e => "err: ${e}" }
    print("T5: ${r5}")

    // Test 6: safe_divide — success
    let r6 = safe_divide(10, 3) catch { e => -1 }
    print("T6: ${r6}")

    // Test 7: safe_divide — fail (div by zero)
    let r7 = safe_divide(10, 0) catch { e => -1 }
    print("T7: ${r7}")

    // Test 8: chained validation — success
    let r8 = chain_validate(10) catch { e => "err: ${e}" }
    print("T8: ${r8}")

    // Test 9: multiple catches in sequence
    let a = safe_divide(20, 4) catch { _ => 0 }
    let b = require_nonempty("x") catch { _ => "default" }
    let c = safe_divide(a, 1) catch { _ => -1 }
    print("T9: ${a} ${b} ${c}")

    // Test 10: nested catch — inner failure caught, outer succeeds
    let inner = safe_divide(1, 0) catch { _ => 42 }
    let outer = safe_divide(inner, 7) catch { _ => -1 }
    print("T10: ${outer}")

    print("adversarial_regress_never_generic: done")
}
