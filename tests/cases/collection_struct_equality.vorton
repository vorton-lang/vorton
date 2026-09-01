// B-023: Verify collection methods use Eq trait dispatch (==) instead of ===

struct Point { x: Int, y: Int }

fn main() {
    // List.contains with struct values
    let p1 = Point { x: 1, y: 2 }
    let p2 = Point { x: 3, y: 4 }
    let points = [p1, p2]
    let target = Point { x: 1, y: 2 }
    assert(points.contains(target), "contains finds equal struct")
    let missing = Point { x: 5, y: 6 }
    assert(!points.contains(missing), "contains returns false for missing")

    // List.index_of with struct values
    let search = Point { x: 3, y: 4 }
    match points.index_of(search) {
        some(i) => assert(i == 1, "index_of returns correct index"),
        none => panic("index_of should find the point")
    }
    let absent = Point { x: 9, y: 9 }
    match points.index_of(absent) {
        some(_) => panic("index_of should return none for missing"),
        none => {}
    }

    // Set.contains with Int (basic check)
    let s = set_from([1, 2, 3])
    assert(s.contains(2), "set contains 2")
    assert(!s.contains(4), "set does not contain 4")

    // Verify basic types still work
    let names = ["alice", "bob"]
    assert(names.contains("alice"), "str contains works")
    assert(!names.contains("charlie"), "str contains negative")

    let nums = [10, 20, 30]
    match nums.index_of(20) {
        some(i) => assert(i == 1, "int index_of works"),
        none => panic("should find 20")
    }

    print("collection_struct_equality: all tests passed")
}
