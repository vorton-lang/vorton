effect OptionStep {
    fn apply(value: Int) -> Int
}

effect OptionScale {
    fn apply(value: Int) -> Int
}

fn main() {
    let s = some(42)
    let n: Option<Int> = none

    // is_some / is_none
    assert(s.is_some(), "some is_some")
    assert(!s.is_none(), "some not is_none")
    assert(n.is_none(), "none is_none")
    assert(!n.is_some(), "none not is_some")

    // unwrap_or
    assert(s.unwrap_or(0) == 42, "some unwrap_or returns inner")
    assert(n.unwrap_or(99) == 99, "none unwrap_or returns default")

    // map
    let doubled = s.map(fn(x) { x * 2 })
    assert(doubled.unwrap_or(0) == 84, "some map applies fn")
    let none_mapped = n.map(fn(x) { x * 2 })
    assert(none_mapped.is_none(), "none map stays none")

    // and_then
    let half = s.and_then(fn(x) {
        if x % 2 == 0 {
            some(x / 2)
        } else {
            none
        }
    })
    assert(half.unwrap_or(0) == 21, "some and_then returns inner option")

    let none_chain = n.and_then(fn(x) { some(x + 1) })
    assert(none_chain.is_none(), "none and_then stays none")

    // chaining
    let result = some(10)
        .map(fn(x) { x + 5 })
        .and_then(fn(x) {
            if x > 10 {
                some(x * 2)
            } else {
                none
            }
        })
        .unwrap_or(0)
    assert(result == 30, "chained option methods")

    // All three callback intrinsics share one open callback ABI. Exercise the
    // pure, one-handled-effect, and two-handled-effect instantiations.
    let pure_map = some(1).map(fn(x) { x + 1 }).unwrap_or(0)
    let pure_chain = some(2).and_then(fn(x) { some(x + 2) }).unwrap_or(0)
    let pure_none: Option<Int> = none
    let pure_fallback = pure_none.unwrap_or_else(fn() { 6 })
    assert(pure_map * 10000 + pure_chain * 100 + pure_fallback == 20406,
        "Option callbacks accept the empty context")

    let one_effect = handle {
        let mapped = some(1)
            .map(fn(x) { OptionStep.apply(x) })
            .unwrap_or(0)
        let chained = some(2)
            .and_then(fn(x) { some(OptionStep.apply(x)) })
            .unwrap_or(0)
        let missing: Option<Int> = none
        let fallback = missing.unwrap_or_else(fn() { OptionStep.apply(3) })
        mapped * 10000 + chained * 100 + fallback
    } with {
        OptionStep.apply(value) => value + 10,
    }
    assert(one_effect == 111213,
        "Option callbacks receive the current one-effect context")

    let two_effects = handle {
        let mapped = some(1).map(fn(x) {
            OptionScale.apply(OptionStep.apply(x))
        }).unwrap_or(0)
        let chained = some(2).and_then(fn(x) {
            some(OptionScale.apply(OptionStep.apply(x)))
        }).unwrap_or(0)
        let missing: Option<Int> = none
        let fallback = missing.unwrap_or_else(fn() {
            OptionScale.apply(OptionStep.apply(3))
        })
        mapped * 10000 + chained * 100 + fallback
    } with {
        OptionStep.apply(value) => value + 10,
        OptionScale.apply(value) => value * 2,
    }
    assert(two_effects == 222426,
        "Option callbacks preserve two exact handled entries")

    // None map/and_then and Some unwrap_or_else must not call their callback.
    // Both handlers count calls, so invoking even a prefix of the callback is
    // observable rather than inferred from the returned Option alone.
    let mut callback_hits = 0
    let absent: Option<Int> = none
    let none_contract = handle {
        let mapped = absent.map(fn(x) {
            OptionScale.apply(OptionStep.apply(x))
        })
        let chained = absent.and_then(fn(x) {
            some(OptionScale.apply(OptionStep.apply(x)))
        })
        let present = some(7).unwrap_or_else(fn() {
            OptionScale.apply(OptionStep.apply(99))
        })
        assert(mapped.is_none() && chained.is_none() && present == 7,
            "Option non-callback branches preserve their values")
        1
    } with {
        OptionStep.apply(value) => {
            callback_hits = callback_hits + 1
            value
        },
        OptionScale.apply(value) => {
            callback_hits = callback_hits + 1
            value
        },
    }
    assert(none_contract == 1 && callback_hits == 0,
        "Option non-callback branches do not invoke hidden closures")

    print("option_methods: all tests passed")
}
