// Test: Cell used in struct impl methods (mut self + Cell interaction)

struct State {
    counter: Cell<Int>,
    name: Str,
}

impl State {
    fn increment(self) {
        self.counter.set(self.counter.get() + 1)
    }

    fn get_count(self) -> Int {
        self.counter.get()
    }

    fn reset(self) {
        self.counter.set(0)
    }
}

fn main() {
    let s = State { counter: Cell(0), name: "test" }
    assert(s.get_count() == 0, "initial count")

    s.increment()
    s.increment()
    s.increment()
    assert(s.get_count() == 3, "after 3 increments")

    s.reset()
    assert(s.get_count() == 0, "after reset")

    // Cell shared between two structs
    let shared = Cell(100)
    let a = State { counter: shared, name: "a" }
    let b = State { counter: shared, name: "b" }
    a.increment()
    assert(b.get_count() == 101, "shared cell through struct")

    print("effect_cell_method: all tests passed")
}
