trait CounterMany {
    fn first(self) -> Int
    fn second(self) -> Option<Int>
}

struct CounterManyInner {}

impl CounterMany for CounterManyInner {
    fn first(self) -> Int { 8 }
    fn second(self) -> Option<Int> { some(9) }
}

struct CounterManyOuter {
    inner: CounterManyInner
}

impl CounterManyOuter {
    delegate inner: CounterMany
}

fn main() {
    let outer = CounterManyOuter { inner: CounterManyInner {} }
    print(outer.first())
    match outer.second() {
        some(value) => print(value),
        none => print(-1),
    }
    let values = [1, 2]
    for value in values {
        print(value)
    }
}
