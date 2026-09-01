// B-130: List.sort() requires T: Ord and uses Ord dispatch (not bare < operator)

fn main() {
    // sort integers
    let mut ints = [10, 2, 1, 20, 3]
    ints.sort()
    assert(ints.get(0).unwrap() == 1, "sort ints first")
    assert(ints.get(1).unwrap() == 2, "sort ints second")
    assert(ints.get(2).unwrap() == 3, "sort ints third")
    assert(ints.get(3).unwrap() == 10, "sort ints fourth")
    assert(ints.get(4).unwrap() == 20, "sort ints last")

    // sort strings (lexicographic)
    let mut strs = ["banana", "apple", "cherry"]
    strs.sort()
    assert(strs.get(0).unwrap() == "apple", "sort strs first")
    assert(strs.get(1).unwrap() == "banana", "sort strs second")
    assert(strs.get(2).unwrap() == "cherry", "sort strs third")

    // sort already-sorted list (idempotent)
    let mut sorted = [1, 2, 3]
    sorted.sort()
    assert(sorted.get(0).unwrap() == 1, "already sorted first")
    assert(sorted.get(2).unwrap() == 3, "already sorted last")

    // sort single-element list
    let mut single = [42]
    single.sort()
    assert(single.get(0).unwrap() == 42, "single element")

    // sort empty list
    let mut empty: List<Int> = []
    empty.sort()
    assert(empty.len() == 0, "empty sort")

    print("list_sort_ord: all tests passed")
}
