// Test: List mutation methods — push, reverse, sort, clear, extend

fn main() {
    // push
    let mut xs = [1, 2, 3]
    xs.push(4)
    assert(xs.len() == 4, "push increases len")
    assert(xs.get(3).unwrap_or(0) == 4, "push adds at end")

    // reverse
    let mut ys = [3, 1, 2]
    ys.reverse()
    assert(ys.get(0).unwrap_or(0) == 2, "reverse [0]")
    assert(ys.get(1).unwrap_or(0) == 1, "reverse [1]")
    assert(ys.get(2).unwrap_or(0) == 3, "reverse [2]")

    // sort
    let mut zs = [3, 1, 4, 1, 5]
    zs.sort()
    assert(zs.get(0).unwrap_or(0) == 1, "sort [0]")
    assert(zs.get(1).unwrap_or(0) == 1, "sort [1]")
    assert(zs.get(4).unwrap_or(0) == 5, "sort [4]")

    // clear
    let mut cs = [1, 2, 3]
    cs.clear()
    assert(cs.len() == 0, "clear empties")
    assert(cs.is_empty(), "clear is_empty")

    // slice
    let sl = [10, 20, 30, 40, 50]
    let mid = sl.slice(1, 4)
    assert(mid.len() == 3, "slice len")
    assert(mid.get(0).unwrap_or(0) == 20, "slice [0]")
    assert(mid.get(2).unwrap_or(0) == 40, "slice [2]")

    // first/last
    let fl = [10, 20, 30]
    assert(fl.first().unwrap_or(0) == 10, "first")
    assert(fl.last().unwrap_or(0) == 30, "last")

    print("list_push_mutate: all tests passed")
}
