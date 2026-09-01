fn find(x: Int) -> Int? {
    if x > 0 { some(x) } else { none }
}

fn try_find(x: Int) -> Int {
    let v = find(x).to_fail("not found")
    v + 1
}

fn main() {
    let a = try_find(-1) catch { _ => 99 }
    let b = try_find(5) catch { _ => 99 }
    print(a)
    print(b)
}
