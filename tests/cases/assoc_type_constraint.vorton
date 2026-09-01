// Associated type constraint: fn foo<T: Trait<Item = Int>>()
trait Source {
    type Item
    fn next(self) -> Item
}

struct IntSource {
    val: Int
}

impl Source for IntSource {
    type Item = Int
    fn next(self) -> Int {
        self.val
    }
}

fn sum_source<T: Source<Item = Int>>(s: T) -> Int {
    s.next() + s.next()
}

fn main() {
    let s = IntSource { val: 5 }
    let result = sum_source(s)
    assert(result == 10, "sum_source should return 10")
    print("assoc type constraint: ok")
}
