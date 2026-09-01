// Review regression for tuple Eq Direct+extra ownership.  ManualBox<T>'s Eq
// dictionary needs the caller's T: Eq evidence, so each tuple leaf dispatch
// materialises a dynamic wrapped dictionary that must be reclaimed after use.

struct ManualBox<T> {
    key: T,
    ignored: Int,
}

impl<T: Eq> Eq for ManualBox<T> {
    fn eq(self, other: ManualBox<T>) -> Bool {
        // Deliberately ignore one field so raw structural comparison is wrong.
        self.key == other.key
    }
}

struct Bomb {
    fuse: Int,
}

impl Eq for Bomb {
    fn eq(self, other: Bomb) -> Bool {
        panic("Bomb.eq must be short-circuited")
    }
}

fn parameterized_tuple_equal<T: Eq>(
    left: ManualBox<T>,
    right: ManualBox<T>
) -> Bool {
    (left, 11) == (right, 11)
}

fn parameterized_closure_equal<T: Eq>(
    target: ManualBox<T>,
    candidate: ManualBox<T>
) -> Bool {
    let expected = (target, ("tag", 22))
    let predicate = fn(actual: (ManualBox<T>, (Str, Int))) -> Bool {
        actual == expected
    }
    predicate((candidate, ("tag", 22)))
}

fn main() {
    assert((1, Bomb { fuse: 0 }) != (2, Bomb { fuse: 0 }),
        "tuple Eq must short-circuit before Bomb.eq")
    assert(parameterized_tuple_equal(
        ManualBox { key: 7, ignored: 1 },
        ManualBox { key: 7, ignored: 999 }
    ), "parameterized tuple must use manual Eq")
    assert(!parameterized_tuple_equal(
        ManualBox { key: 7, ignored: 1 },
        ManualBox { key: 8, ignored: 1 }
    ), "parameterized tuple manual Eq negative")

    let mut matches = 0
    for i in 0..4000 {
        if parameterized_tuple_equal(
            ManualBox { key: i, ignored: i },
            ManualBox { key: i, ignored: 0 - i }
        ) {
            matches = matches + 1
        }
        if parameterized_closure_equal(
            ManualBox { key: i, ignored: i + 1 },
            ManualBox { key: i, ignored: i + 2 }
        ) {
            matches = matches + 1
        }
    }
    assert(matches == 8000, "wrapped tuple hot loop")
    print("tuple_eq_wrapped_dict_rc: all tests passed")
}
