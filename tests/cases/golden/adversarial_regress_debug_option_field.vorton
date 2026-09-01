// B-100 P1.3 R3 regression: derive Debug on generic struct containing Option.
//
// Round 2 fixed dict params for generic derives. This test checks Debug
// output for generic structs whose fields are Option<T> — the Debug derive
// must thread T's Debug dict into the Option's Debug method.
//
// Exercises:
//   * Debug on struct with Option<Int> field (Some + None)
//   * Debug on struct with Option<Str> field
//   * Debug on struct with multiple Option fields
//   * Clone + Eq on struct with Option fields (related derive)

struct Named<T> {
    name: Str,
    value: Option<T>,
}

struct Config {
    host: Option<Str>,
    port: Option<Int>,
    tag: Str,
}

fn main() {
    // Test 1: Debug with Option<Int> Some
    let n1 = Named { name: "x", value: some(42) }
    print("T1: ${n1.debug()}")

    // Test 2: Debug with Option<Int> None
    let n2: Named<Int> = Named { name: "y", value: none }
    print("T2: ${n2.debug()}")

    // Test 3: Debug with Option<Str> Some
    let n3 = Named { name: "z", value: some("hello") }
    print("T3: ${n3.debug()}")

    // Test 4: Debug with Option<Str> None
    let n4: Named<Str> = Named { name: "w", value: none }
    print("T4: ${n4.debug()}")

    // Test 5: Non-generic struct with multiple Option fields
    let c1 = Config { host: some("localhost"), port: some(8080), tag: "dev" }
    print("T5: ${c1.debug()}")

    // Test 6: Mixed Some/None
    let c2 = Config { host: none, port: some(3000), tag: "prod" }
    print("T6: ${c2.debug()}")

    // Test 7: All None
    let c3 = Config { host: none, port: none, tag: "empty" }
    print("T7: ${c3.debug()}")

    // Test 8: Eq on Named<Int> — same
    let eq1 = Named { name: "a", value: some(1) }
    let eq2 = Named { name: "a", value: some(1) }
    print("T8a: ${eq1 == eq2}")

    // Test 9: Eq on Named<Int> — different value
    let eq3 = Named { name: "a", value: some(2) }
    print("T9a: ${eq1 == eq3}")

    // Test 10: Eq on Named<Int> — Some vs None
    let eq4: Named<Int> = Named { name: "a", value: none }
    print("T10a: ${eq1 == eq4}")

    // Test 11: Clone
    let cl = Named { name: "orig", value: some(99) }
    let cl2 = cl.clone()
    print("T11a: ${cl == cl2}")
    print("T11b: ${cl2.debug()}")

    print("adversarial_regress_debug_option_field: done")
}
