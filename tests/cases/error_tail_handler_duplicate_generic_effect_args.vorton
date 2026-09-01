// Audit #258 negative: two explicit labels for the same custom effect denote
// one evidence value, so their generic arguments must agree before the label
// is deduplicated.

effect Slot<T> {
    fn transform(value: T) -> T
}

fn int_use() -> Int with {Slot<Int>} {
    Slot.transform(10)
}

fn str_use() -> Str with {Slot<Str>} {
    Slot.transform("text")
}

fn conflicting_labels() -> Int {
    handle {
        let number = int_use()
        let text = str_use()
        number + text.len()
    } with {
        Slot.transform(value) => value,
    }
}

fn main() {}
