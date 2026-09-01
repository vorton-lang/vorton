fn push_item(mut list: List<Int>, item: Int) {
    list.push(item)
}

fn add_to_map(mut m: Map<Str, Int>, key: Str, value: Int) {
    m.insert(key, value)
}

fn add_to_set(mut s: Set<Int>, item: Int) {
    s.insert(item)
}

fn main() {
    let mut nums = [1, 2, 3]
    push_item(nums, 4)
    assert(nums.len() == 4, "push through mut param")

    let mut m = map_from([("a", 1)])
    add_to_map(m, "b", 2)
    assert(m.len() == 2, "insert through mut param")

    let mut s = set_from([1, 2])
    add_to_set(s, 3)
    assert(s.len() == 3, "insert through mut param to set")

    print("mut_param_enforcement: all tests passed")
}
