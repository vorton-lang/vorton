// Phase 1: handle/with for fail effect (compiles to try/catch)
fn may_fail() -> Int {
    42
}

fn main() {
    let result = handle {
        may_fail()
    } with {
        fail.raise(e) => 0,
    }
    print(result)
}
