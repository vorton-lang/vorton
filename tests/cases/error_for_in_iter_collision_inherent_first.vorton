struct IterSecond { pub value: Int }

impl Iterator for IterSecond {
    type Item = Int
    fn next(mut self) -> Int? { none }
}

struct SourceSecond {}

impl SourceSecond {
    fn iter(self) -> Str { "inherent" }
}

impl Iterable for SourceSecond {
    type Item = Int
    type Iter = IterSecond
    fn iter(self) -> IterSecond { IterSecond { value: 0 } }
}

fn main() {
    for value in (SourceSecond {}) { print(value) }
}
