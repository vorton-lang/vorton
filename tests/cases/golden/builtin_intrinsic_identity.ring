// B-201: fixed builtin method identities must survive inference, HIR
// transports, resource lowering, and exact C ABI projection.

fn main() {
    let scalar = "  ring  ".trim().to_upper()
    let integer = 42
    let decimal: Float = 2.5
    let option_value = some(4)
        .map(fn(x) { x + 1 })
        .and_then(fn(x) { some(x * 2) })
        .unwrap_or_else(fn() { 0 })

    let cell = Cell(3)
    cell.set(option_value)
    cell.update(fn(x) { x + 1 })

    print("${scalar}|${integer.to_str()}|${decimal.to_str()}|${cell.get()}")
}
