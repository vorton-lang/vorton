// B-157 regression: return () in impl methods (and elsewhere) should work
// Previously, `return ()` caused a parse error that silently dropped the
// entire impl block in prelude loading.

struct Counter {
    value: Int
}

impl Counter {
    fn increment(mut self) {
        self.value = self.value + 1
        return ()
    }

    fn reset_if_over(mut self, limit: Int) {
        if self.value <= limit { return () }
        self.value = 0
    }
}

fn do_nothing() {
    return ()
}

fn early_return(x: Int) -> Int {
    if x > 10 { return x }
    // () as expression (not in return)
    let _u = ()
    x + 1
}

fn main() {
    let mut c = Counter { value: 0 }
    c.increment()
    c.increment()
    c.increment()
    print(c.value.to_str())

    c.reset_if_over(10)
    print(c.value.to_str())

    c.reset_if_over(1)
    print(c.value.to_str())

    do_nothing()
    print(early_return(5).to_str())
    print(early_return(15).to_str())
}
