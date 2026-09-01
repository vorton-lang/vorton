// B-146: nested constructor tag checks in the switch path of gen_match_arm_enum.
// Each outer constructor appears exactly once (no guards, no duplicate tags) so
// the compiler takes the switch path, not the if-else fallback. The inner
// constructor tag must still be verified before binding variables.

enum Inner {
    A(Int),
    B(Int),
}

enum Outer {
    One(Inner),
    Two(Inner),
    Three,
}

fn describe(o: Outer) -> Str {
    match o {
        One(A(n)) => "one-a-${n}",
        Two(B(n)) => "two-b-${n}",
        _ => "other",
    }
}

// Named-constructor variant to cover NamedConstructor branch
enum NInner {
    X { val: Int },
    Y { val: Int },
}

enum NOuter {
    P(NInner),
    Q(NInner),
}

fn describe_named(o: NOuter) -> Str {
    match o {
        P(X { val }) => "p-x-${val}",
        Q(Y { val }) => "q-y-${val}",
        _ => "named-other",
    }
}

fn main() {
    // Matching cases: outer + inner tag both match
    print(describe(One(A(1))))
    print(describe(Two(B(2))))

    // Non-matching inner tag: outer matches but inner does not → wildcard
    print(describe(One(B(99))))
    print(describe(Two(A(99))))

    // Outer tag has no nested pattern → wildcard
    print(describe(Three))

    // Named constructor tests
    print(describe_named(P(X { val: 10 })))
    print(describe_named(Q(Y { val: 20 })))

    // Non-matching inner tag → wildcard
    print(describe_named(P(Y { val: 30 })))
    print(describe_named(Q(X { val: 40 })))
}
