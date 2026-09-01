// Cell shared through closure
fn main() {
    let counter = Cell(0)
    let inc = fn() { counter.set(counter.get() + 1) }
    inc()
    inc()
    inc()
    print(counter.get())
}
