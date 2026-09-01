// B-130: List.sort() Ord dispatch — both backends must produce identical sorted output.
// Covers Int and Str element types (the two most common Ord instances).

fn main() {
    let mut ints = [5, 3, 1, 4, 2]
    ints.sort()
    print("ints: ${ints.get(0).unwrap()},${ints.get(1).unwrap()},${ints.get(2).unwrap()},${ints.get(3).unwrap()},${ints.get(4).unwrap()}")

    let mut strs = ["cherry", "apple", "banana"]
    strs.sort()
    print("strs: ${strs.get(0).unwrap()},${strs.get(1).unwrap()},${strs.get(2).unwrap()}")

    // empty + single-element (edge cases)
    let mut empty: List<Int> = []
    empty.sort()
    print("empty len: ${empty.len()}")

    let mut single = [42]
    single.sort()
    print("single: ${single.get(0).unwrap()}")
}
