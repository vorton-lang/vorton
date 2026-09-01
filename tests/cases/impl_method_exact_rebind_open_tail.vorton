trait ApplyOnce {
    fn apply(self, callback) -> Int
}

struct Runner {}

impl ApplyOnce for Runner {
    fn apply(self, callback) -> Int {
        callback(10)
    }
}

fn noisy(value: Int) -> Int with {console} {
    print("noisy=${value}")
    value + 2
}

fn main() {
    let pure = (Runner {}).apply(fn(value) { value + 1 })
    let effectful = (Runner {}).apply(noisy)
    print("results=${pure}/${effectful}")
}
