// Test: (K, V)? should be equivalent to Option<(K, V)>

fn find_pair(x: Int) -> (Int, Str)? {
    if x > 0 { some((x, "found")) } else { none }
}

fn transform(t: (Int, Str)?) -> (Int, Bool)? {
    match t {
        some((n, s)) => some((n, s == "found")),
        none => none,
    }
}

fn main() {
    // Basic: tuple option variable
    let x: (Int, Str)? = some((1, "hello"))
    let v = match x {
        some((a, b)) => a,
        none => 0,
    }
    assert(v == 1, "basic tuple option some")

    let y: (Int, Str)? = none
    let w = match y {
        some((a, b)) => a,
        none => -1,
    }
    assert(w == -1, "basic tuple option none")

    // Nested tuple option
    let z: ((Int, Str), Bool)? = some(((42, "nested"), true))
    let nv = match z {
        some(((n, s), b)) => n,
        none => 0,
    }
    assert(nv == 42, "nested tuple option")

    let z2: ((Int, Str), Bool)? = none
    let nv2 = match z2 {
        some(((n, s), b)) => n,
        none => -1,
    }
    assert(nv2 == -1, "nested tuple option none")

    // Function param and return
    let r1 = find_pair(10)
    let r1v = match r1 {
        some((n, s)) => n,
        none => 0,
    }
    assert(r1v == 10, "fn return tuple option some")

    let r2 = find_pair(-1)
    let r2v = match r2 {
        some((n, s)) => n,
        none => -1,
    }
    assert(r2v == -1, "fn return tuple option none")

    let t1 = transform(some((5, "found")))
    let t1v = match t1 {
        some((n, b)) => b,
        none => false,
    }
    assert(t1v == true, "fn param tuple option transform")

    let t2 = transform(none)
    let t2v = match t2 {
        some((n, b)) => true,
        none => false,
    }
    assert(t2v == false, "fn param tuple option none")

    print("pass: tuple option sugar")
}
