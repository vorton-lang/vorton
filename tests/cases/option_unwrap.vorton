fn find(x: Int) -> Int? {
    if x > 0 { some(x) } else { none }
}

fn use_find() -> Int {
    let v = find(42).to_fail("not found")
    v + 1
}

fn main() {
    let result = use_find() catch { _ => 0 }
    print(result)
}
