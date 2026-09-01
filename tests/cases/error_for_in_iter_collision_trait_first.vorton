struct IterFirst { pub value: Int }

impl Iterator for IterFirst {
    type Item = Int
    fn next(mut self) -> Int? { none }
}

struct SourceFirst {}

impl Iterable for SourceFirst {
    type Item = Int
    type Iter = IterFirst
    fn iter(self) -> IterFirst { IterFirst { value: 0 } }
}

impl SourceFirst {
    fn iter(self) -> Str { "inherent" }
}

fn main() {
    for value in (SourceFirst {}) { print(value) }
}
