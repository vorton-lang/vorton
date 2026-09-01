// B-100 P1.3 R3 regression: combined test exercising ALL Round 2 fix areas.
//
// This test combines:
//   1. Generic derive (Eq/Debug) — 3-layer nesting
//   2. Closure evidence capture — closure calling effectful fn
//   3. Map/Set HOF — chained operations
//   4. Never type — match arms with fail
//
// If any of the 4 fixes regressed, this test should catch it through
// cross-cutting interactions.

struct Box<T> {
    val: T,
}

fn unwrap_or_fail<T: Eq>(opt: Option<T>, msg: Str) -> T with {fail<Str>} {
    match opt {
        some(v) => v,
        none => fail.raise(msg),
    }
}

fn main() {
    // ── Area 1: generic derive through closures ──
    let b1 = Box { val: 42 }
    let b2 = Box { val: 42 }
    let b3 = Box { val: 99 }

    // Closure capturing generic struct + using Eq
    let checker = fn() -> Bool { b1 == b2 }
    print("T1a: ${checker()}")

    let checker2 = fn() -> Str { b3.debug() }
    print("T1b: ${checker2()}")

    // ── Area 2: closure + effect + Never ──
    let r2 = {
        let validate = fn(x: Int) -> Int {
            unwrap_or_fail(some(x), "unreachable")
        }
        validate(10)
    } catch { e => -1 }
    print("T2a: ${r2}")

    let r2b = {
        let validate = fn() -> Int {
            let o: Option<Int> = none
            unwrap_or_fail(o, "was none")
        }
        validate()
    } catch { e => -1 }
    print("T2b: ${r2b}")

    // ── Area 3: Map HOF + generic derive ──
    let mut m: Map<Str, Int> = map_new()
    m.insert("x", 10)
    m.insert("y", 20)
    m.insert("z", 30)

    // fold to build a summary string
    let summary = m.fold("", fn(acc, k, v) { "${acc}${k}=${v};" })
    print("T3a: ${summary}")

    // filter + fold chain
    let big = m.filter(fn(k, v) { v > 15 })
    let sum = big.fold(0, fn(acc, k, v) { acc + v })
    print("T3b: sum=${sum}")

    // Box comparison through closure
    let boxes = [Box { val: 10 }, Box { val: 20 }]
    let found = boxes.any(fn(b) { b == Box { val: 20 } })
    print("T3c: found=${found}")

    // ── Area 4: Never in match + generic + closure ──
    let r4a = unwrap_or_fail(some(1), "missing") catch { _ => -1 }
    let n: Option<Int> = none
    let r4b = unwrap_or_fail(n, "missing") catch { _ => -1 }
    let r4c = unwrap_or_fail(some(3), "missing") catch { _ => -1 }
    print("T4: ${r4a},${r4b},${r4c}")

    // ── Area 5: all areas in one expression ──
    let mut data: Map<Str, Int> = map_new()
    data.insert("a", 5)
    data.insert("b", 0)
    data.insert("c", 15)

    let any_big = data.any(fn(k, v) { v > 10 })
    print("T5a: any_big=${any_big}")

    let mapped = data.map_values(fn(v) { v + 1 })
    let mapped_str = mapped.fold("", fn(acc, k, v) { "${acc}${k}=${v};" })
    print("T5b: ${mapped_str}")

    print("adversarial_regress_combo_all_fixes: done")
}
