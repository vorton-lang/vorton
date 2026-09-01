fn main() {
    // List indexing
    let list = [10, 20, 30]
    assert(list[0] == 10, "list[0]")
    assert(list[1] == 20, "list[1]")
    assert(list[2] == 30, "list[2]")

    // Map indexing
    let map = map_from([("a", 1), ("b", 2)])
    assert(map["a"] == 1, "map[a]")
    assert(map["b"] == 2, "map[b]")

    // String indexing
    let s = "hello"
    assert(s[0] == "h", "str[0]")
    assert(s[4] == "o", "str[4]")

    // Nested indexing
    let nested = [[1, 2], [3, 4]]
    assert(nested[0][1] == 2, "nested")

    // Index with expression
    let i = 1
    assert(list[i] == 20, "list[i] with variable")
    assert(list[1 + 1] == 30, "list[1+1]")

    // .get() still works
    let opt = list.get(0)
    assert(opt.unwrap() == 10, ".get() still works")

    print("index_expr: all tests passed")
}
