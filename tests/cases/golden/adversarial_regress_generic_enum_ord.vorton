// B-100 P1.3 R3 regression: generic enum derive Ord — multi-variant with
// generic payloads.
//
// Round 2 fixed dict params for generic derive. This test pushes the Ord
// derive on a generic enum with multiple variants carrying generic payloads.
// The derived cmp must:
//   1. Compare variant tags first
//   2. For same-variant, compare payloads using T's Ord dict
//
// Exercises:
//   * Generic enum Ord with unit + payload variants
//   * Ordering comparison (<, >, ==) on generic enum
//   * Through generic fn dispatch (larger/smaller)
//   * Sorting a list of generic enums

enum Prio<T> {
    None,
    Low(T),
    High(T),
}

fn larger<T: Ord>(a: T, b: T) -> T {
    if a > b { a } else { b }
}

fn smaller<T: Ord>(a: T, b: T) -> T {
    if a < b { a } else { b }
}

fn main() {
    // Test 1: unit variant vs payload variant ordering (None < Low < High)
    let n: Prio<Int> = Prio::None
    let lo = Prio::Low(1)
    let hi = Prio::High(1)
    print("T1a: ${n < lo}")
    print("T1b: ${lo < hi}")
    print("T1c: ${n < hi}")

    // Test 2: same variant, different payload (Ord on Int payload)
    let lo1 = Prio::Low(10)
    let lo2 = Prio::Low(20)
    print("T2a: ${lo1 < lo2}")
    print("T2b: ${lo2 > lo1}")
    print("T2c: ${lo1 == lo1}")

    // Test 3: same variant, Str payload
    let s1: Prio<Str> = Prio::High("alpha")
    let s2: Prio<Str> = Prio::High("beta")
    print("T3a: ${s1 < s2}")
    print("T3b: ${s2 > s1}")

    // Test 4: None == None
    let n1: Prio<Int> = Prio::None
    let n2: Prio<Int> = Prio::None
    print("T4: ${n1 == n2}")

    // Test 5: through generic dispatch — larger
    let r5 = larger(Prio::Low(5), Prio::High(1))
    match r5 {
        Prio::High(v) => print("T5: High(${v})"),
        _ => print("T5: wrong"),
    }

    // Test 6: through generic dispatch — smaller
    let r6 = smaller(Prio::Low(5), Prio::High(1))
    match r6 {
        Prio::Low(v) => print("T6: Low(${v})"),
        _ => print("T6: wrong"),
    }

    // Test 7: cross-variant with same-tag different payload through generic
    let r7 = larger(Prio::Low(100), Prio::Low(50))
    match r7 {
        Prio::Low(v) => print("T7: Low(${v})"),
        _ => print("T7: wrong"),
    }

    print("adversarial_regress_generic_enum_ord: done")
}
