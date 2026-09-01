// B-100 P1.3 R3 regression: double-nested closure + effect evidence capture.
//
// Round 2 fixed collect_captures for Call node evidence. This test pushes
// the fix with double-nested closures where the innermost closure calls
// an effect operation. The evidence must be threaded through both closure
// layers.
//
// Exercises:
//   * Double-nested closure calling fail.raise
//   * Double-nested closure calling custom effect op
//   * Closure capturing variables across nested catch scopes
//   * Closure in list.map calling effectful function

effect Logger {
    fn log(msg: Str) -> Unit
}

fn risky(x: Int) -> Str with {fail<Str>} {
    if x < 0 { fail.raise("negative") }
    "ok(${x})"
}

fn main() {
    // Test 1: double-nested closure + fail — success path
    let r1 = {
        let outer = fn() -> Str {
            let inner = fn() -> Str {
                risky(5)
            }
            inner()
        }
        outer()
    } catch { e => "caught: ${e}" }
    print("T1: ${r1}")

    // Test 2: double-nested closure + fail — failure path
    let r2 = {
        let outer = fn() -> Str {
            let inner = fn() -> Str {
                risky(-1)
            }
            inner()
        }
        outer()
    } catch { e => "caught: ${e}" }
    print("T2: ${r2}")

    // Test 3: closure captures catch result, used in another closure
    let caught = risky(-3) catch { e => "fallback(${e})" }
    let fmt = fn(s: Str) -> Str { "${caught}/${s}" }
    print("T3: ${fmt("extra")}")

    // Test 4: nested closures where outer captures catch result
    let val = risky(7) catch { _ => "default" }
    let outer = fn() -> Str {
        let inner = fn() -> Str { "inner(${val})" }
        "outer(${inner()})"
    }
    print("T4: ${outer()}")

    // Test 5: custom effect through nested closure
    let r5 = handle {
        let outer = fn() -> Str {
            let msg = Logger.log("step1")
            let inner = fn() -> Str {
                Logger.log("step2")
                "done"
            }
            inner()
        }
        outer()
    } with {
        Logger.log(m) => {
            print("LOG: ${m}")
            ""
        },
    }
    print("T5: ${r5}")

    // Test 6: closure in list.map calling effectful function — all succeed
    let items = [1, 2, 3]
    let r6 = items.map(fn(x) { risky(x) }) catch { e => ["error"] }
    print("T6: ${r6.join(",")}")

    // Test 7: closure in list.map where second item causes fail
    let mixed = [1, -1, 3]
    let r7 = {
        let results = mixed.map(fn(x) { risky(x) })
        results.join(",")
    } catch { e => "failed: ${e}" }
    print("T7: ${r7}")

    // Test 8: multiple sequential catches with closures between them
    let a = risky(1) catch { _ => "a_err" }
    let b = risky(-1) catch { _ => "b_err" }
    let c = risky(2) catch { _ => "c_err" }
    let combine = fn() -> Str { "${a}|${b}|${c}" }
    print("T8: ${combine()}")

    print("adversarial_regress_closure_nested_effect: done")
}
