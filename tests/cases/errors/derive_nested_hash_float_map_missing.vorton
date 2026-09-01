struct Inner<T> {
    value: T
}

struct Outer<T> {
    nested: Inner<Inner<T>>
}

fn main() {
    let key = Outer {
        nested: Inner { value: Inner { value: 1.5 } }
    }
    let mut values: Map<Outer<Float>, Int> = map_new()
    values.insert(key, 107)
}
