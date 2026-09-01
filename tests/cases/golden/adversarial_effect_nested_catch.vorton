// B-100 P1.3: adversarial — nested catch blocks.
// Inner catch handles one error, outer catch handles another.
// Tests that nested setjmp/longjmp frames interact correctly.

enum Inner { InnerErr }
enum Outer { OuterErr }

fn fail_inner() -> Int with {fail<Inner>} {
    fail.raise(Inner::InnerErr)
}

fn fail_outer() -> Int with {fail<Outer>} {
    fail.raise(Outer::OuterErr)
}

fn maybe_inner(x: Int) -> Int with {fail<Inner>} {
    if x < 0 { fail.raise(Inner::InnerErr) }
    x
}

fn maybe_outer(x: Int) -> Int with {fail<Outer>} {
    if x < 0 { fail.raise(Outer::OuterErr) }
    x
}

fn main() {
    // Test 1: inner catch catches, outer not triggered
    let r1 = {
        let inner_result = fail_inner() catch { _ => -1 }
        maybe_outer(inner_result + 100)
    } catch { _ => -999 }
    print("T1: ${r1.to_str()}")

    // Test 2: inner catch succeeds (no fail), outer gets triggered
    let r2 = {
        let inner_result = maybe_inner(10) catch { _ => -1 }
        maybe_outer(-(inner_result + 100))
    } catch { _ => -77 }
    print("T2: ${r2.to_str()}")

    // Test 3: inner catch catches inner, then outer fail triggers outer catch
    let r3 = {
        let a = fail_inner() catch { _ => 5 }
        print("inner caught: ${a.to_str()}")
        fail_outer()
    } catch { _ => -77 }
    print("T3: ${r3.to_str()}")

    // Test 4: multiple sequential catches — each independent
    let r4a = fail_inner() catch { _ => 1 }
    let r4b = fail_inner() catch { _ => 2 }
    let r4c = maybe_inner(30) catch { _ => 3 }
    print("T4: ${r4a.to_str()},${r4b.to_str()},${r4c.to_str()}")

    // Test 5: catch in a loop — each iteration has its own catch frame
    let mut results = ""
    for i in 0..5 {
        let r = maybe_inner(if i == 2 || i == 4 { -1 } else { i }) catch { _ => -1 }
        if results == "" { results = r.to_str() }
        else { results = "${results},${r.to_str()}" }
    }
    print("T5: ${results}")

    // Test 6: deeply nested — three levels of catch
    let r6 = {
        let a = {
            let b = fail_inner() catch { _ => 10 }
            maybe_outer(b + 1)
        } catch { _ => 20 }
        maybe_inner(a + 1) catch { _ => 30 }
    }
    print("T6: ${r6.to_str()}")

    print("adversarial_effect_nested_catch: done")
}
