// B-100 P1.1 parity: set operations — union, intersect, difference,
// to_list, contains, len.

fn main() {
    let a = set_from([1, 2, 3, 4, 5])
    let b = set_from([3, 4, 5, 6, 7])

    // Contains
    print("a_has3=${a.contains(3)}")
    print("a_has6=${a.contains(6)}")

    // Len
    print("a_len=${a.len()}")
    print("b_len=${b.len()}")

    // Union
    let u = a.union(b)
    print("union_len=${u.len()}")
    print("union_has1=${u.contains(1)}")
    print("union_has7=${u.contains(7)}")

    // Intersect
    let i = a.intersect(b)
    print("inter_len=${i.len()}")
    print("inter_has3=${i.contains(3)}")
    print("inter_has1=${i.contains(1)}")
    print("inter_has7=${i.contains(7)}")

    // Difference
    let d = a.difference(b)
    print("diff_len=${d.len()}")
    print("diff_has1=${d.contains(1)}")
    print("diff_has2=${d.contains(2)}")
    print("diff_has3=${d.contains(3)}")

    // Empty set operations
    let empty: Set<Int> = set_from([])
    let eu = empty.union(a)
    print("empty_union=${eu.len()}")
    let ei = empty.intersect(a)
    print("empty_inter=${ei.len()}")
}
