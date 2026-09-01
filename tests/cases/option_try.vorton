fn risky(x: Int) -> Int {
    if x > 0 { x } else { fail.raise("negative") }
}

fn main() {
    let a = some(risky(42)) catch { _ => none }
    let b = some(risky(-1)) catch { _ => none }
    let va = match a { some(v) => v, none => 0 }
    let vb = match b { some(v) => v, none => 0 }
    print(va + vb)
}
