struct Resource {
    id: Int
}

impl Drop for Resource {
    fn drop(self) {}
}

struct Wrapper<T> {
    value: T
}

struct Sink<T> {
    value: T
}

fn own(value: Wrapper<Resource>) -> Unit {
    let sink = Sink { value: value }
}

fn main() {
    let wrapped = Wrapper { value: Resource { id: 1 } }
    own(wrapped)
    print(wrapped.value.id)
}
