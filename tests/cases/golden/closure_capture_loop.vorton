// B-083 #3 regression (the hard one): closures created INSIDE a loop body each
// capture the SAME outer heap variable.  Each iteration builds a fresh closure
// that takes its own reference, so the captured variable must be dup-ed once
// PER ITERATION.
//
// Two wrong behaviours this guards against:
//   - missing per-iteration dup (single-pass backward analysis treats the
//     capture as a last-use → moves it into the first closure) → later closures
//     hold a dangling pointer → UAF / corrupted output under LLVM.
//   - double-dup (conservative once-before-loop dup PLUS per-iteration dup) is a
//     leak only, so it would not corrupt output — but the per-iteration logic
//     must still dup exactly once per closure for the refcounts to balance.
//
// Output must match golden .expected file.

fn call0(f: fn() -> Str) -> Str { f() }

fn main() {
    let base = "B-${40 + 2}"          // heap Str captured by every loop closure

    let mut fns: List<fn() -> Str> = []
    for i in 0..4 {
        // each iteration creates a NEW closure capturing `base` (and `i`)
        fns.push(fn() -> Str { "${base}#${i}" })
    }

    // `base` is also used after the loop (non-last across the whole scope).
    print("base=${base}")

    // Invoke every closure built across the loop iterations.  If a per-iteration
    // dup was missing, the later closures read freed memory.
    for f in fns {
        print(call0(f))
    }
}
