fn read_then<T>(
    source: Cell<T>,
    callback: fn(T) -> T
) -> T {
    callback(source.get())
}

fn main() {
    let number = Cell(4)
    let text = Cell("ring")
    let number_after_text = fn(value: Int) -> Int {
        if text.get() == "ring" { value + 1 } else { value }
    }
    let text_after_number = fn(value: Str) -> Str {
        if number.get() == 4 { value } else { "wrong" }
    }

    let first = read_then(number, number_after_text)
    let second = read_then(text, text_after_number)

    assert(first == 5 && second == "ring",
        "generic mut<T> atom and open tail instantiate without order guessing")
    print("D_GENERIC_EFFECT_ORDER_OK:${first}/${second}")
}
