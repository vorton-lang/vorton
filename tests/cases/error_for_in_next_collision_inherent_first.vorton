struct NextSecond {}

impl NextSecond {
    fn next(mut self) -> Str? { none }
}

impl Iterator for NextSecond {
    type Item = Int
    fn next(mut self) -> Int? { none }
}

impl Iterable for NextSecond {
    type Item = Int
    type Iter = NextSecond
    fn iter(self) -> NextSecond { self }
}

fn main() {
    for value in (NextSecond {}) { print(value) }
}
