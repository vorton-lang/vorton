fn main() {
    // list_clone
    let xs = [1, 2, 3]
    let mut ys = list_clone(xs)
    ys.push(4)
    assert(xs.len() == 3, "original list unchanged after clone push")
    assert(ys.len() == 4, "cloned list has new element")

    // set_clone
    let s1 = set_from([10, 20, 30])
    let mut s2 = set_clone(s1)
    s2.insert(40)
    assert(s1.len() == 3, "original set unchanged after clone insert")
    assert(s2.len() == 4, "cloned set has new element")

    // map_clone (already existed, verify still works)
    let m1 = map_from([("a", 1)])
    let mut m2 = map_clone(m1)
    m2.insert("b", 2)
    assert(m1.len() == 1, "original map unchanged after clone insert")
    assert(m2.len() == 2, "cloned map has new entry")

    print("api_clone: all tests passed")
}
