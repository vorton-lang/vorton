effect SortOrder {
    fn compare(left: Int, right: Int) -> Int
}

effect SortScale {
    fn preserve(value: Int) -> Int
}

fn compare_with_current(left: Int, right: Int) -> Int with {SortOrder} {
    SortOrder.compare(left, right)
}

fn compare_with_two(left: Int, right: Int) -> Int with {SortOrder, SortScale} {
    SortScale.preserve(SortOrder.compare(left, right))
}

fn main() {
    // sort_by ascending
    let mut xs = [3, 1, 4, 1, 5]
    xs.sort_by(fn(a, b) { a - b })
    match xs.get(0) {
        some(v) => assert(v == 1, "asc first"),
        none => assert(false, "asc first none")
    }
    match xs.get(4) {
        some(v) => assert(v == 5, "asc last"),
        none => assert(false, "asc last none")
    }

    // sort_by descending
    let mut ys = [3, 1, 4, 1, 5]
    ys.sort_by(fn(a, b) { b - a })
    match ys.get(0) {
        some(v) => assert(v == 5, "desc first"),
        none => assert(false, "desc first none")
    }
    match ys.get(4) {
        some(v) => assert(v == 1, "desc last"),
        none => assert(false, "desc last none")
    }

    // sort_by strings by length
    let mut words = ["hi", "hello", "hey"]
    words.sort_by(fn(a, b) { a.len() - b.len() })
    match words.get(0) {
        some(v) => assert(v == "hi", "shortest first"),
        none => assert(false, "shortest first none")
    }

    // The exact runtime sort bridge synchronously forwards the caller's
    // borrowed context to every comparator invocation.
    let mut effectful = [4, 2, 3, 1]
    let mut comparisons = 0
    let completed = handle {
        effectful.sort_by(compare_with_current)
        1
    } with {
        SortOrder.compare(left, right) => {
            comparisons = comparisons + 1
            left - right
        },
    }
    assert(completed == 1 && comparisons > 0 &&
        effectful[0] == 1 && effectful[3] == 4,
        "sort comparator receives the current handled context")

    // A second comparator performs both exact handled effects. The scale arm
    // multiplies by a positive value so comparison signs and ordering remain
    // unchanged while both context entries stay observable.
    let mut two_effectful = [8, 6, 7, 5]
    let mut order_hits = 0
    let mut scale_hits = 0
    let two_completed = handle {
        two_effectful.sort_by(compare_with_two)
        1
    } with {
        SortOrder.compare(left, right) => {
            order_hits = order_hits + 1
            left - right
        },
        SortScale.preserve(value) => {
            scale_hits = scale_hits + 1
            value * 2
        },
    }
    assert(two_completed == 1 && order_hits > 0 && scale_hits > 0 &&
        two_effectful[0] == 5 && two_effectful[3] == 8,
        "sort comparator receives two exact handled context entries")

    print("sort_by: all tests passed")
}
