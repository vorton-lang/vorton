pub struct Resource {
    pub id: Int,
    payload: Str
}

impl Drop for Resource {
    fn drop(self) {}
}

pub struct Boxed<T> {
    pub value: T
}

fn inspect(value: Boxed<Resource>) -> Int {
    value.value.id
}

fn move_box(value: Boxed<Resource>) -> Boxed<Resource> {
    value
}

pub fn parity_value() -> Int {
    let original = Boxed {
        value: Resource { id: 41, payload: "parity" }
    }
    let before = inspect(original)
    let moved = move_box(original)
    before + moved.value.id
}
