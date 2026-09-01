// B-100 P1.3: adversarial — fail inside a for loop.
// Tests that loop variable cleanup and iteration state are handled
// correctly when fail.raise fires mid-iteration (longjmp vs try/catch).

enum E { Stopped { at: Int } }

fn check(n: Int) -> Int with {fail<E>} {
    if n == 3 { fail.raise(E::Stopped { at: n }) }
    n
}

fn main() {
    // Test 1: fail in middle of list iteration
    let r1 = {
        let items = [1, 2, 3, 4, 5]
        let mut sum = 0
        for item in items {
            print("loop1: ${item.to_str()}")
            sum = sum + check(item)
        }
        sum.to_str()
    } catch { _ => "stopped" }
    print("T1: ${r1}")

    // Test 2: fail in range loop via check function
    let r2 = {
        for i in 0..10 {
            print("loop2: ${i.to_str()}")
            check(i)
        }
        "completed"
    } catch { _ => "stopped" }
    print("T2: ${r2}")

    // Test 3: fail in nested loop — inner loop fails
    let r3 = {
        for i in 0..3 {
            for j in 0..3 {
                print("loop3: ${i.to_str()},${j.to_str()}")
                if i == 1 && j == 2 {
                    check(3)
                }
            }
        }
        "completed"
    } catch { _ => "stopped" }
    print("T3: ${r3}")

    // Test 4: loop completes normally — check never triggers (all < 3)
    let r4 = {
        let mut count = 0
        for i in 0..3 {
            count = count + check(i)
        }
        count.to_str()
    } catch { _ => "failed" }
    print("T4: ${r4}")

    print("adversarial_effect_fail_in_loop: done")
}
