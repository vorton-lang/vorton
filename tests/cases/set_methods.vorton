// Test: Set methods — filter, fold, any, all, comprehensive

fn main() {
    let s = set_from([1, 2, 3, 4, 5])

    // filter
    let evens = s.filter(fn(x) { x % 2 == 0 })
    assert(evens.len() == 2, "set filter evens")
    assert(evens.contains(2), "filter has 2")
    assert(evens.contains(4), "filter has 4")

    // fold
    let sum = s.fold(0, fn(acc, x) { acc + x })
    assert(sum == 15, "set fold sum")

    // any
    assert(s.any(fn(x) { x == 3 }), "set any true")
    assert(!s.any(fn(x) { x > 10 }), "set any false")

    // all
    assert(s.all(fn(x) { x > 0 }), "set all positive")
    assert(!s.all(fn(x) { x > 3 }), "set not all > 3")

    // to_list
    let lst = s.to_list()
    assert(lst.len() == 5, "set to_list len")

    // insert and remove (mutation)
    let mut s2 = set_new()
    s2.insert(10)
    s2.insert(20)
    assert(s2.len() == 2, "set insert len")
    s2.remove(10)
    assert(s2.len() == 1, "set remove len")
    assert(!s2.contains(10), "set removed 10")
    assert(s2.contains(20), "set still has 20")

    print("set_methods: all tests passed")
}
