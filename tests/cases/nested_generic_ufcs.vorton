struct Pair<A, B> {
    pub first: A,
    pub second: B
}

struct Triple<A, B, C> {
    pub a: A,
    pub b: B,
    pub c: C
}

fn main() {
    // ---- 2 levels of nesting ----
    let p = Pair { first: Pair { first: 1, second: 2 }, second: 3 }
    let q = Pair { first: Pair { first: 1, second: 2 }, second: 3 }
    let r = Pair { first: Pair { first: 9, second: 9 }, second: 3 }

    // Operator ==
    assert(p == q, "op == equal")
    assert(p != r, "op != different")

    // Direct .eq() UFCS
    assert(p.eq(q), "direct .eq() equal")
    assert(p.eq(r) == false, "direct .eq() different")

    // .debug()
    let dbg = p.debug()
    assert(dbg.len() > 0, "debug non-empty")

    // .clone()
    let c = p.clone()
    assert(c == p, "clone equality")
    assert(c.eq(p), "clone .eq()")

    // .cmp()
    assert(p.cmp(q) == 0, "cmp equal")
    assert(p.cmp(r) < 0, "cmp less")

    // ---- 3 levels of nesting ----
    let deep = Pair { first: Pair { first: Pair { first: 1, second: 2 }, second: 3 }, second: 4 }
    let deep2 = Pair { first: Pair { first: Pair { first: 1, second: 2 }, second: 3 }, second: 4 }
    let deep3 = Pair { first: Pair { first: Pair { first: 9, second: 9 }, second: 3 }, second: 4 }

    assert(deep == deep2, "3-level op ==")
    assert(deep.eq(deep2), "3-level .eq()")
    assert(deep.eq(deep3) == false, "3-level .eq() different")
    assert(deep.debug().len() > 0, "3-level .debug()")
    let dc = deep.clone()
    assert(dc.eq(deep), "3-level clone .eq()")
    assert(deep.cmp(deep2) == 0, "3-level .cmp() equal")

    // ---- Enum with nested generic ----
    let t1 = Triple { a: Pair { first: 1, second: "x" }, b: true, c: 42 }
    let t2 = Triple { a: Pair { first: 1, second: "x" }, b: true, c: 42 }
    assert(t1 == t2, "triple op ==")
    assert(t1.eq(t2), "triple .eq()")
    assert(t1.debug().len() > 0, "triple .debug()")
    let tc = t1.clone()
    assert(tc.eq(t1), "triple clone .eq()")

    print("nested generic ufcs: all ok")
}
