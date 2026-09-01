// Guards inside recursion and inside an effectful (fail) context. Exercises the
// guarded-match lowering when arm bodies recurse and when the match sits in a
// function carrying a fail<E> effect, and when a guard itself raises.
enum E { TooBig }

// Guarded recursion: classify each step, accumulate via recursion.
fn count_down(n: Int) -> Str {
    match n {
        x if x <= 0 => "done",
        x if x % 2 == 0 => "even(${x}) ${count_down(x - 1)}",
        x => "odd(${x}) ${count_down(x - 1)}"
    }
}

// Guard in a fail-effect context; one arm's guard triggers a raise.
fn checked(n: Int) -> Int with {fail<E>} {
    match n {
        x if x > 10 => fail.raise(E::TooBig),
        x if x > 0 => x * 2,
        _ => 0
    }
}

fn main() {
    print(count_down(4))            // even(4) odd(3) even(2) odd(1) done

    let a = checked(3) catch { _ => -1 }
    print("checked 3: ${a}")        // checked 3: 6

    let b = checked(50) catch { _ => -1 }
    print("checked 50: ${b}")       // checked 50: -1

    let c = checked(-2) catch { _ => -1 }
    print("checked -2: ${c}")       // checked -2: 0
}
