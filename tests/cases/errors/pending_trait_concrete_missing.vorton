trait Marker {
    fn marker(self) -> Int
}

struct NoMarker { value: Int }

fn count_tags<T: Marker>(items: List<T>) -> Int {
    items.len()
}

fn main() {
    print(count_tags([NoMarker { value: 1 }]))
}
