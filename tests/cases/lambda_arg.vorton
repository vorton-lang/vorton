// TestGap T7: Lambda passed as argument
fn apply(f: fn(Int) -> Int, x: Int) -> Int {
    f(x)
}

fn main() {
    let double = fn(x: Int) -> Int { x * 2 }
    print(apply(double, 21))
    print(apply(fn(x: Int) -> Int { x + 1 }, 5))
}
