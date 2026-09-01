// Regression: generic trait impl + explicit method + __prefix naming convention
trait Summable {
    fn total(self) -> Int
    fn label(self) -> Str
}

struct Scores {
    values: List<Int>,
}

impl Summable for Scores {
    fn total(self) -> Int {
        self.values.fold(0, fn(acc, x) { acc + x })
    }
    fn label(self) -> Str { "total=${self.total()}" }
}

struct Counts {
    a: Int,
    b: Int,
}

impl Summable for Counts {
    fn total(self) -> Int {
        self.a + self.b
    }
    fn label(self) -> Str { "total=${self.total()}" }
}

fn show_total<T: Summable>(x: T) -> Str {
    x.label()
}

fn sum_both<T: Summable, U: Summable>(a: T, b: U) -> Int {
    a.total() + b.total()
}

fn main() {
    let s = Scores { values: [10, 20, 30] }
    assert(s.total() == 60, "scores total")
    assert(show_total(s) == "total=60", "show scores label")

    let c = Counts { a: 7, b: 3 }
    assert(c.total() == 10, "counts total")
    assert(show_total(c) == "total=10", "show counts label")

    assert(sum_both(s, c) == 70, "sum both")

    print("trait_generic_impl: all passed")
}
