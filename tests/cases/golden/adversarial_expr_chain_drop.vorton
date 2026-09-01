// B-100 P1.3 adversarial: chained method calls — intermediate temporary drop timing.
//
// In `list.filter(f).map(g)`, the filter() result is an intermediate temporary
// that is consumed by map(). The key question: does the backend drop the
// intermediate List at the right time? If the intermediate is dropped too early
// (before map reads it) => native crash; too late (never dropped) => leak
// divergence won't show in output but RC imbalance accumulates.
//
// This test exercises:
//   * Simple 2-step chain: filter then map
//   * 3-step chain: filter -> map -> filter
//   * Chain ending in fold (consumes + produces scalar)
//   * Chain ending in len() (scalar extraction from temp)
//   * Chain result bound to let vs used directly in print
//   * Chained method on a fresh constructor (not a variable)

fn double(x: Int) -> Int {
    x * 2
}

fn is_even(x: Int) -> Bool {
    x % 2 == 0
}

fn main() {
    let xs = [1, 2, 3, 4, 5, 6, 7, 8]

    // 2-step chain: filter -> map, result bound to let
    let evens_doubled = xs.filter(fn(x) { x % 2 == 0 }).map(fn(x) { x * 2 })
    print("chain2=${evens_doubled.len()}")
    for v in evens_doubled {
        print("  ${v}")
    }

    // 3-step chain: filter -> map -> filter
    let result3 = xs
        .filter(fn(x) { x > 2 })
        .map(fn(x) { x * 3 })
        .filter(fn(x) { x < 20 })
    print("chain3=${result3.len()}")
    for v in result3 {
        print("  ${v}")
    }

    // Chain ending in fold: intermediate list temp created then consumed
    let sum = xs.filter(fn(x) { x > 4 }).fold(0, fn(acc, x) { acc + x })
    print("chain_fold=${sum}")

    // Chain ending in len() — scalar extraction from temp list
    let count = xs.filter(fn(x) { x % 3 == 0 }).len()
    print("chain_len=${count}")

    // Chain on a fresh list literal (not a variable)
    let fresh_chain = [10, 20, 30, 40, 50]
        .filter(fn(x) { x > 20 })
        .map(fn(x) { x + 1 })
    print("fresh=${fresh_chain.len()}")
    for v in fresh_chain {
        print("  ${v}")
    }

    // Multiple chains in sequence — ensures prior chain temps are dropped
    // before next chain starts
    let a = [1, 2, 3].filter(fn(x) { x > 1 }).len()
    let b = [4, 5, 6].filter(fn(x) { x > 4 }).len()
    let c = [7, 8, 9].filter(fn(x) { x > 7 }).len()
    print("seq=${a},${b},${c}")
}
