// B-163 / audit #221: tuple equality carries a recursive Eq evidence plan.

struct ManualKey {
    identity: Int,
    ignored: Str,
}

impl Eq for ManualKey {
    fn eq(self, other: ManualKey) -> Bool {
        // Deliberately differs from raw field equality.  Tuple equality must
        // call this implementation rather than compare the struct payload.
        self.identity == other.identity
    }
}

fn tuple_equal<T: Eq>(left: (T, Str), right: (T, Str)) -> Bool {
    left == right
}

fn nested_closure_equal<T: Eq>(
    target: (T, (Str, T)),
    candidate: (T, (Str, T))
) -> Bool {
    // The lambda must capture every generic dictionary referenced recursively
    // by its tuple dispatch plan.
    let predicate = fn(value: (T, (Str, T))) -> Bool { value == target }
    predicate(candidate)
}

fn make_left() -> (Int, Int) with {console} {
    print("left")
    (1, 2)
}

fn make_right() -> (Int, Int) with {console} {
    print("right")
    (1, 2)
}

fn main() {
    let manual_left = (ManualKey { identity: 7, ignored: "left" }, "tag")
    let manual_right = (ManualKey { identity: 7, ignored: "right" }, "tag")
    let manual_other = (ManualKey { identity: 8, ignored: "left" }, "tag")
    assert(manual_left == manual_right, "tuple must honor manual Eq")
    assert(manual_left != manual_other, "tuple manual Eq negative")

    assert(tuple_equal((10, "x"), (10, "x")), "generic tuple builtin Eq")
    assert(tuple_equal(manual_left, manual_right), "generic tuple manual Eq")
    assert(nested_closure_equal(
        (ManualKey { identity: 4, ignored: "a" },
            ("nested", ManualKey { identity: 5, ignored: "b" })),
        (ManualKey { identity: 4, ignored: "c" },
            ("nested", ManualKey { identity: 5, ignored: "d" }))
    ), "nested closure tuple evidence")

    // Output proves the tuple operands are evaluated exactly once, left first.
    assert(make_left() == make_right(), "tuple operands evaluate once")
    print("tuple_eq_dispatch: all tests passed")
}
