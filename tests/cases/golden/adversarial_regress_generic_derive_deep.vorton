// B-100 P1.3 R3 regression: 3-layer nested generic struct Eq + Ord + Debug.
//
// Round 2 fixed dict params passing for generic derive Eq/Ord/Debug.
// This test stresses the fix with 3-layer deep nesting:
//   struct A<T> -> struct B<T> -> struct C<T> -> T
// The compiler must thread T's dicts through all 3 layers.
//
// Exercises:
//   * 3-layer nested generic struct Eq
//   * 3-layer nested generic struct through generic fn dispatch
//   * Debug on nested generic struct (C<T>, B<T>, A<T>)
//   * Eq with different concrete types (Int, Str, Bool)

struct C_inner<T> {
    z: T,
}

struct B_mid<T> {
    y: C_inner<T>,
}

struct A_outer<T> {
    x: B_mid<T>,
}

fn are_equal<T: Eq>(a: T, b: T) -> Bool {
    a == b
}

fn main() {
    // Test 1: 3-layer Int — equal
    let a1 = A_outer { x: B_mid { y: C_inner { z: 42 } } }
    let a2 = A_outer { x: B_mid { y: C_inner { z: 42 } } }
    print("T1: ${a1 == a2}")

    // Test 2: 3-layer Int — not equal (deep value differs)
    let a3 = A_outer { x: B_mid { y: C_inner { z: 99 } } }
    print("T2: ${a1 == a3}")

    // Test 3: 3-layer Str — equal
    let s1 = A_outer { x: B_mid { y: C_inner { z: "hello" } } }
    let s2 = A_outer { x: B_mid { y: C_inner { z: "hello" } } }
    print("T3: ${s1 == s2}")

    // Test 4: 3-layer Str — not equal
    let s3 = A_outer { x: B_mid { y: C_inner { z: "world" } } }
    print("T4: ${s1 == s3}")

    // Test 5: 3-layer Bool
    let b1 = A_outer { x: B_mid { y: C_inner { z: true } } }
    let b2 = A_outer { x: B_mid { y: C_inner { z: true } } }
    let b3 = A_outer { x: B_mid { y: C_inner { z: false } } }
    print("T5a: ${b1 == b2}")
    print("T5b: ${b1 == b3}")

    // Test 6: through generic fn dispatch (double indirection)
    print("T6a: ${are_equal(a1, a2)}")
    print("T6b: ${are_equal(a1, a3)}")
    print("T6c: ${are_equal(s1, s2)}")
    print("T6d: ${are_equal(s1, s3)}")

    // Test 7: Debug on each layer
    let c = C_inner { z: 7 }
    print("T7a: ${c.debug()}")
    let b = B_mid { y: C_inner { z: 8 } }
    print("T7b: ${b.debug()}")
    let a = A_outer { x: B_mid { y: C_inner { z: 9 } } }
    print("T7c: ${a.debug()}")

    // Test 8: Debug on Str-parameterized nested
    let cs = C_inner { z: "hi" }
    print("T8: ${cs.debug()}")

    print("adversarial_regress_generic_derive_deep: done")
}
