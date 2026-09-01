// B-100 P1.1 parity: collection structural equality — List.contains with structs,
// Set operations, nested collection equality.

struct Item { id: Int, name: Str }

fn main() {
    // List.contains with struct
    let p1 = Item { id: 1, name: "a" }
    let p2 = Item { id: 2, name: "b" }
    let items = [p1, p2]
    let target = Item { id: 1, name: "a" }
    print("contains_yes=${items.contains(target)}")       // contains_yes=true
    let missing = Item { id: 3, name: "c" }
    print("contains_no=${items.contains(missing)}")       // contains_no=false

    // List.index_of with struct
    let search = Item { id: 2, name: "b" }
    match items.index_of(search) {
        some(i) => print("index_of=${i}"),                // index_of=1
        none => print("index_of=FAIL"),
    }

    // Set with primitives — contains
    let s = set_from([10, 20, 30])
    print("set_has_20=${s.contains(20)}")                 // set_has_20=true
    print("set_has_99=${s.contains(99)}")                 // set_has_99=false
    print("set_len=${s.len()}")                           // set_len=3

    // Set union / intersect / difference
    let a = set_from([1, 2, 3])
    let b = set_from([2, 3, 4])
    let u = a.union(b)
    print("union_len=${u.len()}")                         // union_len=4
    let i = a.intersect(b)
    print("intersect_len=${i.len()}")                     // intersect_len=2
    let d = a.difference(b)
    print("diff_len=${d.len()}")                          // diff_len=1
    print("diff_has_1=${d.contains(1)}")                  // diff_has_1=true

    // Struct equality directly
    let x = Item { id: 5, name: "e" }
    let y = Item { id: 5, name: "e" }
    let z = Item { id: 5, name: "f" }
    print("struct_eq=${x == y}")                          // struct_eq=true
    print("struct_ne=${x == z}")                          // struct_ne=false

    // Nested: list of lists
    let nested = [[1, 2], [3, 4]]
    print("nested_len=${nested.len()}")                   // nested_len=2
    print("inner_len=${nested[0].len()}")                 // inner_len=2
    print("inner_val=${nested[1][1]}")                    // inner_val=4
}
