// B-104 D2 regression: break/continue edges drop the loop-scoped owned set.
//
// THE CHANGE THIS PINS: perceus rc_stmt's Break/Continue arms emit drops for
// every owned binding declared inside the innermost loop body
// (visible_owned[loop_base..]) before the jump — previously those bindings
// leaked once per break and once per ITERATION for continue (verifier class
// leak-loop-exit, 264 sites in the compiler alone).
//
// THE UAF RISK THIS PINS: the loop-exit drops must release ONLY loop-scoped
// bindings, exactly once per path.  Wrong sets (enclosing bindings dropped /
// double drop with the block-end drops / outer-loop locals dropped by an
// inner break) over-free values the continuation still uses — the golden
// .expected pins the surviving values (escaped results, shared dups, outer locals).

// continue + break in a for loop; escaped value must survive the drops.
fn collect_long(names: List<Str>, min_len: Int) -> List<Str> {
    let mut out: List<Str> = []
    for n in names {
        let upper = n.to_upper()
        if upper.len() < min_len {
            continue
        }
        if upper.starts_with("STOP") {
            break
        }
        out.push(upper)
    }
    out
}

// break out of a while loop after escaping a loop-local into an outer mut var:
// the escape Clone must keep `found`'s value alive past the break-edge drops.
fn first_match(xs: List<Int>, threshold: Int) -> Int {
    let mut found = 0 - 1
    let mut i = 0
    while i < xs.len() {
        let v = xs[i]
        let doubled = v * 2
        if doubled > threshold {
            found = doubled
            break
        }
        i = i + 1
    }
    found
}

// continue with a shared (Clone'd element read) loop-local: the continue-edge
// drop releases the dup, the list element must survive for later iterations.
fn sum_odd(xs: List<Int>) -> Int {
    let mut total = 0
    let mut i = 0
    while i < xs.len() {
        let v = xs[i]
        i = i + 1
        if v % 2 == 0 {
            continue
        }
        total = total + v
    }
    total
}

// nested loops: an inner break drops only inner-scoped bindings; the
// outer-loop local stays valid after the inner loop exits.
fn pair_sum(xs: List<Int>) -> Int {
    let mut acc = 0
    for a in xs {
        let base = a + 100
        for b in xs {
            let combo = base + b
            if combo > 104 {
                break
            }
            acc = acc + combo
        }
        acc = acc + base
    }
    acc
}

fn main() {
    let names = ["ab", "alpha", "STOPHERE", "beta"]
    let longs = collect_long(names, 3)
    print("longs=${longs.len()}")
    for s in longs {
        print(s)
    }
    print("first=${first_match([1, 5, 9, 2], 9)}")
    print("sumodd=${sum_odd([1, 2, 3, 4, 5])}")
    print("pairsum=${pair_sum([1, 2, 3])}")
}
