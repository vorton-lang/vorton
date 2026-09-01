// Test: for..in with List and various iteration patterns

fn main() {
    // for..in over list
    let xs = [10, 20, 30]
    let mut sum = 0
    for x in xs {
        sum = sum + x
    }
    assert(sum == 60, "for in list sum")

    // for..in with break
    let ys = [1, 2, 3, 4, 5]
    let mut first_gt3 = 0
    for y in ys {
        if y > 3 {
            first_gt3 = y
            break
        }
    }
    assert(first_gt3 == 4, "for in list with break")

    // for..in with continue
    let mut even_sum = 0
    for z in [1, 2, 3, 4, 5, 6] {
        if z % 2 != 0 { continue }
        even_sum = even_sum + z
    }
    assert(even_sum == 12, "for in list with continue")

    // for..in over Set
    let s = set_from([10, 20, 30])
    let mut set_sum = 0
    for item in s {
        set_sum = set_sum + item
    }
    assert(set_sum == 60, "for in set")

    // Nested for..in
    let grid = [[1, 2], [3, 4]]
    let mut total = 0
    for row in grid {
        for val in row {
            total = total + val
        }
    }
    assert(total == 10, "nested for in list")

    print("for_list_methods: all tests passed")
}
