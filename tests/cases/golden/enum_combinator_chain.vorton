// B-093 regression (enum higher-order combinator intermittent double-free):
// A user-defined Result-like enum with `and_then` / `map_ok` combinators that
// take `fn(v) {...}` closures, chained across multiple closures. This exercises
// the interaction between enum payload RC (the Ok(Int)/Err(Str) payload) and the
// closure argument RC (the fn passed into and_then/map_ok). The combinator moves
// the payload into the closure call and returns a fresh enum; the outer chain
// must not double-drop the payload nor the closure env.
//
// Intermittently double-freed / crashed in str_from_cstr on the LLVM backend
// before the fix (~2/200 standalone, ~1/3 full-suite).

enum Res { Ok(Int), Err(Str) }

impl Res {
    // higher-order: takes a closure that maps the Ok payload to a new Res
    fn and_then(self, f: fn(Int) -> Res) -> Res {
        match self {
            Res::Ok(v) => f(v),
            Res::Err(e) => Res::Err(e)
        }
    }

    // higher-order: takes a closure that maps the Ok payload value
    fn map_ok(self, f: fn(Int) -> Int) -> Res {
        match self {
            Res::Ok(v) => Res::Ok(f(v)),
            Res::Err(e) => Res::Err(e)
        }
    }

    fn show(self) -> Str {
        match self {
            Res::Ok(v) => "ok(${v})",
            Res::Err(e) => "err(${e})"
        }
    }
}

fn double(x: Int) -> Res {
    if x < 100 { Res::Ok(x * 2) } else { Res::Err("overflow") }
}

fn main() {
    // Chain several higher-order combinators with distinct fn(v){} closures.
    let r1 = Res::Ok(5)
        .and_then(fn(v) { double(v) })          // Ok(10)
        .map_ok(fn(v) { v + 1 })                // Ok(11)
        .and_then(fn(v) { double(v) })          // Ok(22)
        .map_ok(fn(v) { v * 3 })                // Ok(66)
    print("r1: ${r1.show()}")                   // r1: ok(66)

    // A chain that errors mid-way: the Err(Str) payload threads through the
    // remaining combinators (closure not invoked) — exercises payload move on
    // the Err arm + closure env drop without invocation.
    let r2 = Res::Ok(60)
        .and_then(fn(v) { double(v) })          // Ok(120) ... 120 still < ... no: 60*2=120
        .and_then(fn(v) { double(v) })          // 120 >= 100 => Err("overflow")
        .map_ok(fn(v) { v + 1 })                // Err threads through
        .and_then(fn(v) { double(v) })          // Err threads through
    print("r2: ${r2.show()}")                   // r2: err(overflow)

    // Start from Err directly: every combinator drops its closure unused.
    let r3 = Res::Err("boom")
        .map_ok(fn(v) { v + 100 })
        .and_then(fn(v) { double(v) })
    print("r3: ${r3.show()}")                   // r3: err(boom)

    // Loop the chain many times so any intermittent RC imbalance accumulates.
    let mut ok_count = 0
    for i in 0..50 {
        let r = Res::Ok(i)
            .map_ok(fn(v) { v + 1 })
            .and_then(fn(v) { double(v) })
            .map_ok(fn(v) { v + 7 })
        match r {
            Res::Ok(_) => { ok_count = ok_count + 1 }
            Res::Err(_) => {}
        }
    }
    print("ok_count: ${ok_count}")              // ok_count: 50 (i in 0..49, v+1 in 1..50, double < 100)
}
