trait CounterOne {
    fn value(self) -> Option<Int>
}

struct CounterOneInner {}

impl CounterOne for CounterOneInner {
    fn value(self) -> Option<Int> { some(7) }
}

struct CounterOneOuter {
    inner: CounterOneInner
}

impl CounterOneOuter {
    delegate inner: CounterOne
}

fn main() {
    let outer = CounterOneOuter { inner: CounterOneInner {} }
    match outer.value() {
        some(value) => print(value),
        none => print(-1),
    }
    let values = [1]
    for value in values {
        print(value)
    }
}
