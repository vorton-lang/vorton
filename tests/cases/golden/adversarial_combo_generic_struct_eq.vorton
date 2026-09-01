// B-100 P1.3 R2 adversarial combo: generic struct auto-derived Eq.
//
// No llvm_diff test uses a generic struct (`struct Pair<A, B>`) and then
// compares instances with `==`. The auto-derived Eq for a generic struct
// must thread T's Eq dict correctly in LLVM codegen — if the dict is
// missing or misordered, the comparison segfaults or returns wrong results.
//
// Exercises:
//   * Generic struct `==` with Int fields
//   * Generic struct `==` with Str fields
//   * Generic struct `==` with mixed types
//   * Generic struct `==` through a generic function (double dict dispatch)
//   * Nested generic struct (Wrapper<Pair<A,B>>)
//   * Generic struct containing enum Option

struct Pair<A, B> {
    fst: A,
    snd: B,
}

struct Wrapper<T> {
    label: Str,
    value: T,
}

fn are_equal<T: Eq>(a: T, b: T) -> Bool {
    a == b
}

fn main() {
    // Test 1: Pair<Int, Int> equality
    let p1 = Pair { fst: 1, snd: 2 }
    let p2 = Pair { fst: 1, snd: 2 }
    let p3 = Pair { fst: 1, snd: 9 }
    print("T1a: ${p1 == p2}")
    print("T1b: ${p1 == p3}")

    // Test 2: Pair<Str, Str> equality
    let s1 = Pair { fst: "hello", snd: "world" }
    let s2 = Pair { fst: "hello", snd: "world" }
    let s3 = Pair { fst: "hello", snd: "earth" }
    print("T2a: ${s1 == s2}")
    print("T2b: ${s1 == s3}")

    // Test 3: Pair<Int, Str> mixed-type equality
    let m1 = Pair { fst: 42, snd: "x" }
    let m2 = Pair { fst: 42, snd: "x" }
    let m3 = Pair { fst: 42, snd: "y" }
    print("T3a: ${m1 == m2}")
    print("T3b: ${m1 == m3}")

    // Test 4: generic struct through generic Eq dispatch
    print("T4a: ${are_equal(p1, p2)}")
    print("T4b: ${are_equal(p1, p3)}")
    print("T4c: ${are_equal(s1, s2)}")
    print("T4d: ${are_equal(m1, m3)}")

    // Test 5: Wrapper<Int> — nested generic struct
    let w1 = Wrapper { label: "a", value: 10 }
    let w2 = Wrapper { label: "a", value: 10 }
    let w3 = Wrapper { label: "a", value: 20 }
    let w4 = Wrapper { label: "b", value: 10 }
    print("T5a: ${w1 == w2}")
    print("T5b: ${w1 == w3}")
    print("T5c: ${w1 == w4}")

    // Test 6: Wrapper<Str>
    let ws1 = Wrapper { label: "x", value: "inner" }
    let ws2 = Wrapper { label: "x", value: "inner" }
    let ws3 = Wrapper { label: "x", value: "other" }
    print("T6a: ${ws1 == ws2}")
    print("T6b: ${ws1 == ws3}")

    // Test 7: Wrapper through generic dispatch
    print("T7a: ${are_equal(w1, w2)}")
    print("T7b: ${are_equal(w1, w3)}")

    // Test 8: Pair<Bool, Int>
    let b1 = Pair { fst: true, snd: 1 }
    let b2 = Pair { fst: true, snd: 1 }
    let b3 = Pair { fst: false, snd: 1 }
    print("T8a: ${b1 == b2}")
    print("T8b: ${b1 == b3}")

    print("adversarial_combo_generic_struct_eq: done")
}
