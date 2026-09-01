trait Marker {
    fn marker(self) -> Int
}

impl Marker for Int {
    fn marker(self) -> Int { self }
}

fn count_tags<T: Marker>(items: List<T>) -> Int {
    items.len()
}

fn main() {
    // T is hidden from the Int result and has no annotation or sibling source.
    print(count_tags([]))
}
