struct Envelope<T> {
    value: T
}

fn clone_envelope<T: Clone>(value: Envelope<T>) -> Envelope<T> {
    value.clone()
}

fn main() {
    let original = Envelope { value: [[1, 2], [3]] }
    let copied = clone_envelope(original)
    let mut copied_inner = copied.value.get(0).unwrap()
    copied_inner.push(4)
    assert(original.value.get(0).unwrap().len() == 2,
        "generic Clone bound preserves the original")
    assert(copied.value.get(0).unwrap().len() == 3,
        "generic Clone bound reaches nested containers")
    print("A_GENERIC_CLONE_OK")
}
