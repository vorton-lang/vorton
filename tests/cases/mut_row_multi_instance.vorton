// Audit #265 regression: mut<T> is a multi-instance marker effect.
// One effect row legitimately carries mut<Int> and mut<Str> at the same time,
// and a bare `with {mut}` instantiation (fresh state-type variable) merged
// into such a row must not force every instance onto one state type.
// The original #258 merge contract unified all same-kind pairs and rejected
// this program with E0301 (cannot unify Str with ?N).

fn bump_bare(c: Cell<Int>) -> Int with {mut} {
    c.set(c.get() + 1)
    c.get()
}

fn main() {
    let a = Cell(1)
    let b = Cell("hello")
    a.set(2)
    b.set("world")

    // Closure whose effect row carries the bare-mut fresh instance; calling it
    // merges that row into main's mixed [mut<Int>, mut<Str>] row.
    let through_closure = fn() -> Int { bump_bare(a) }
    let n = through_closure()

    assert(n == 3, "bare mut instantiation after mixed mut row")
    assert(b.get() == "world", "Cell<Str> instance unaffected")
    print("mut_row_multi_instance: all tests passed")
}
