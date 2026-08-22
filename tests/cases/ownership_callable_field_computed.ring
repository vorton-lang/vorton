struct CallbackBox {
    callback: fn(Int) -> Option<Int>
}

fn apply_box(box: CallbackBox, value: Int) -> Option<Int> {
    (box.callback)(value)
}

fn main() {
    let box = CallbackBox {
        callback: fn(value: Int) -> Option<Int> { some(value + 1) }
    }
    match apply_box(box, 6) {
        some(value) => print(value),
        none => print(-1),
    }
}
