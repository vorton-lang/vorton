// B-100 P1.1 parity: Cell.update — callback-style mutation on Cell,
// Cell with different types, multiple updates in sequence.
// Output must match golden .expected file.

fn main() {
    // Basic Cell update
    let c = Cell(10)
    c.update(fn(x) { x + 5 })
    print("update1=${c.get()}")

    // Multiple updates
    c.update(fn(x) { x * 2 })
    print("update2=${c.get()}")

    // Update with captured variable
    let factor = 3
    c.update(fn(x) { x * factor })
    print("update3=${c.get()}")

    // Cell of Str
    let s = Cell("hello")
    s.update(fn(x) { "${x} world" })
    print("str_update=${s.get()}")

    // Cell get/set basics (for completeness alongside update)
    let c2 = Cell(100)
    print("initial=${c2.get()}")
    c2.set(200)
    print("after_set=${c2.get()}")
    c2.update(fn(x) { x + 50 })
    print("after_update=${c2.get()}")
}
