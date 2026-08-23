use ops::{scalar_text, option_value}

fn main() {
    let cell = Cell(option_value(5))
    cell.update(fn(x) { x + 5 })
    print("${scalar_text(7, 2.5)}|${cell.get()}")
}
