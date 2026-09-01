// expect error: E0301

fn will_fail() -> Int with {fail<Str>} {
    fail.raise(42)
}

fn main() {
    let x = will_fail() catch { _ => 0 }
    print(x.to_str())
}
