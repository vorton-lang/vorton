fn main() {
    // concat returns new list, original unchanged
    let a = [1, 2, 3]
    let b = a.concat([4, 5])
    assert(a.len() == 3, "original unchanged")
    assert(b.len() == 5, "concat result has all")

    // extend mutates in-place
    let mut c = [1, 2, 3]
    c.extend([4, 5])
    assert(c.len() == 5, "extend mutated")

    // concat does not modify original
    let d = [1, 2].concat([3])
    assert(d.len() == 3, "concat result length")

    // chaining
    let e = [1].concat([2]).concat([3])
    assert(e.len() == 3, "concat chain")

    print("list_concat_extend: all tests passed")
}
