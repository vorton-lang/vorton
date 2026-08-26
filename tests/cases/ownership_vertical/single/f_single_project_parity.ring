struct Resource {
    id: Int,
    payload: Str
}

impl Drop for Resource {
    fn drop(self) {}
}

struct Boxed<T> {
    value: T
}

fn inspect(value: Boxed<Resource>) -> Int {
    value.value.id
}

fn move_box(value: Boxed<Resource>) -> Boxed<Resource> {
    value
}

fn parity_value() -> Int {
    let original = Boxed {
        value: Resource { id: 41, payload: "parity" }
    }
    let before = inspect(original)
    let moved = move_box(original)
    before + moved.value.id
}

fn main() {
    print("F_PARITY:${parity_value()}")
}
