fn might_fail(x: Int) -> Int {
    if x < 0 {
        fail.raise("negative")
    }
    x * 2
}

fn main() {
    let result = handle { might_fail(21) } with {
        fail.raise(e) => -1
    }
    print(result)
}
