struct Inner<T> {
    value: T
}

struct Outer<T> {
    nested: Inner<Inner<T>>
}

fn main() {
    let value = Outer {
        nested: Inner { value: Inner { value: 1.5 } }
    }
    value.hash()
}
