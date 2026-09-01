// B-100 P1.1 parity: index expressions — list[i], map[key], str[i],
// nested indexing, expression as index.

fn main() {
    // List index
    let xs = [10, 20, 30, 40, 50]
    print("list0=${xs[0]}")
    print("list2=${xs[2]}")
    print("list4=${xs[4]}")

    // Map index
    let m = map_from([("a", 1), ("b", 2), ("c", 3)])
    print("map_a=${m["a"]}")
    print("map_c=${m["c"]}")

    // String index
    let s = "hello"
    print("str0=${s[0]}")
    print("str4=${s[4]}")

    // Nested index (list of lists)
    let nested = [[1, 2], [3, 4], [5, 6]]
    print("nested01=${nested[0][1]}")
    print("nested10=${nested[1][0]}")
    print("nested21=${nested[2][1]}")

    // Expression as index
    let arr = [100, 200, 300]
    let idx = 1
    print("expr_idx=${arr[idx]}")
    print("computed=${arr[1 + 1]}")
}
