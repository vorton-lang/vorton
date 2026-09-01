// expect success

fn will_fail() -> Int with {fail<Str>} {
    fail.raise("error")
    42
}

fn main() {
    let x = will_fail() catch { _ => 0 }
    print(x.to_str())
}
