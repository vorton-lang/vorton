struct HasCallback {
    handler: fn(Int) -> Int
}

fn main() {
    let left = (HasCallback { handler: fn(x) { x } }, 1)
    let right = (HasCallback { handler: fn(x) { x + 1 } }, 1)
    print(left == right)
}
