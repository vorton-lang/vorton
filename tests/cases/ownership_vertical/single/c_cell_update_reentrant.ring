fn main() {
    let cell = Cell("seed")
    cell.update(fn(old) {
        cell.set("interim")
        "${old}-final"
    })

    let result = cell.get()
    assert(result == "seed-final",
        "Cell.update keeps the detached old value live across reentrant set")
    assert(cell.get() == "seed-final",
        "Cell.update replaces the reentrant interim value with callback result")
    print("C_CELL_UPDATE_REENTRANT_OK:${result}")
}
