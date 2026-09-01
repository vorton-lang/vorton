struct Callback {
    name: Str,
    action: fn(Int) -> Int
}

fn main() {
    let cb = Callback { name: "double", action: fn(x: Int) -> Int { x * 2 } }
    let s = cb.debug()
    assert(s.contains("<fn>"), "FnType field should show <fn>")
    print(s)
}
