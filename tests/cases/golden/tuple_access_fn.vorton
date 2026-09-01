// B-100 P1.1 parity: tuple field access + tuple functions — .0/.1 field
// access, nested tuple access, functions returning tuples, tuple
// destructuring.

fn swap(t: (Int, Str)) -> (Str, Int) {
    let (a, b) = t
    (b, a)
}

fn make_pair(x: Int) -> (Int, Int) {
    (x, x * 2)
}

fn sum_triple(t: (Int, Int, Int)) -> Int {
    t.0 + t.1 + t.2
}

fn main() {
    // Basic field access
    let pair = (42, "hello")
    print("p0=${pair.0}")
    print("p1=${pair.1}")

    // Triple field access
    let triple = (1, 2, 3)
    print("t0=${triple.0}")
    print("t1=${triple.1}")
    print("t2=${triple.2}")

    // Nested tuple access
    let nested = ((10, 20), "x")
    print("n00=${nested.0.0}")
    print("n01=${nested.0.1}")
    print("n1=${nested.1}")

    // Function returning tuple + destructuring
    let result = swap((42, "answer"))
    let (s, n) = result
    print("swap_s=${s}")
    print("swap_n=${n}")

    // Make pair function
    let mp = make_pair(5)
    print("mp0=${mp.0}")
    print("mp1=${mp.1}")

    // Sum triple function
    print("sum=${sum_triple((10, 20, 30))}")
}
