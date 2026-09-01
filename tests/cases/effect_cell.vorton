// Cell<T> + mut effect propagation
fn increment(c: Cell<Int>) {
    c.set(c.get() + 1)
}

fn main() {
    let c = Cell(0)
    increment(c)
    increment(c)
    print(c.get())
}
