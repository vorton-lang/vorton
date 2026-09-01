struct NextFirst {}

impl Iterator for NextFirst {
    type Item = Int
    fn next(mut self) -> Int? { none }
}

impl NextFirst {
    fn next(mut self) -> Str? { none }
}

impl Iterable for NextFirst {
    type Item = Int
    type Iter = NextFirst
    fn iter(self) -> NextFirst { self }
}

fn main() {
    for value in (NextFirst {}) { print(value) }
}
