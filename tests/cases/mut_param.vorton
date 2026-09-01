// mut<T> parameterized effect — Cell<T> carries mut<T> effect type

// Effect annotation with mut<Int>
fn use_cell(c: Cell<Int>) -> Int with {mut<Int>} {
    c.set(c.get() + 1)
    c.get()
}

// Bare mut annotation (backward compatible)
fn use_cell_bare(c: Cell<Int>) -> Int with {mut} {
    c.set(c.get() + 1)
    c.get()
}

fn main() {
    // Basic: single Cell mut<Int>
    let x = Cell(42)
    x.set(10)
    assert(x.get() == 10, "Cell<Int> basic set/get")

    // Multiple Cells with different types
    let a = Cell(1)
    let b = Cell("hello")
    a.set(2)
    b.set("world")
    assert(a.get() == 2, "Cell<Int> after multi-cell")
    assert(b.get() == "world", "Cell<Str> after multi-cell")

    // Test annotated function
    let c = Cell(0)
    let result = use_cell(c)
    assert(result == 1, "mut<Int> annotated function")

    // Test bare mut annotated function
    let c2 = Cell(10)
    let result2 = use_cell_bare(c2)
    assert(result2 == 11, "bare mut annotated function")

    print("mut_param: all tests passed")
}
