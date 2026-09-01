// B-100 P1.3: adversarial — fail in nested function call arguments.
// f(g(h())) where h() fails — tests that argument evaluation order
// and drop timing are correct under LLVM (setjmp/longjmp).

enum E { Boom }

fn h(x: Int) -> Int with {fail<E>} {
    if x == 0 { fail.raise(E::Boom) }
    x * 10
}

fn g(x: Int) -> Int {
    x + 1
}

fn f(x: Int) -> Str {
    "result=${x.to_str()}"
}

fn main() {
    // Test 1: h succeeds — all three called
    let r1 = f(g(h(5))) catch { _ => "caught" }
    print("T1: ${r1}")

    // Test 2: h fails — g and f should NOT be called
    let r2 = f(g(h(0))) catch { _ => "caught" }
    print("T2: ${r2}")

    // Test 3: sequential — first h succeeds, second fails
    let r3 = {
        let a = h(1)
        let b = h(0)
        f(g(a + b))
    } catch { _ => "caught-seq" }
    print("T3: ${r3}")

    // Test 4: deeply nested — g(g(g(h(fail)))) catch returns Int
    let r4 = g(g(g(h(0)))) catch { _ => -1 }
    print("T4: ${r4.to_str()}")

    // Test 5: h in middle position — g(h(g(x)))
    let r5 = g(h(g(0))) catch { _ => -1 }
    print("T5: ${r5.to_str()}")

    // Test 6: multiple h calls — first succeeds
    let r6 = {
        let x = h(3)
        let y = h(2)
        x + y
    } catch { _ => -1 }
    print("T6: ${r6.to_str()}")

    print("adversarial_effect_nested_call_fail: done")
}
