fn main() {
    let original_nested = [[1, 2], [3]]
    let copied_nested: List<List<Int>> = original_nested.clone()
    let mut copied_first = copied_nested.get(0).unwrap()
    copied_first.push(9)
    assert(original_nested.get(0).unwrap().len() == 2,
        "nested List clone keeps the original independent")
    assert(copied_nested.get(0).unwrap().len() == 3,
        "nested List clone owns its inner clone")

    let original_option: Option<List<Int>> = some([4, 5])
    let copied_option: Option<List<Int>> = original_option.clone()
    let mut copied_option_list = copied_option.unwrap()
    copied_option_list.push(6)
    assert(original_option.unwrap().len() == 2,
        "Option<List<Int>> clone keeps the original independent")
    assert(copied_option_list.len() == 3,
        "Option<List<Int>> clone owns its payload clone")

    let original_map: Map<Int, List<Int>> = map_from([(1, [7, 8])])
    let copied_map: Map<Int, List<Int>> = original_map.clone()
    let mut copied_map_value = copied_map.get(1).unwrap()
    copied_map_value.push(9)
    assert(original_map.get(1).unwrap().len() == 2,
        "Map clone keeps the original value independent")
    assert(copied_map.get(1).unwrap().len() == 3,
        "Map clone owns its value clone")

    let original_set: Set<Int> = set_from([10, 20])
    let mut copied_set: Set<Int> = original_set.clone()
    copied_set.insert(30)
    assert(original_set.len() == 2,
        "Set clone keeps the original independent")
    assert(copied_set.len() == 3,
        "Set clone owns its cloned entries")

    print("A_DEEP_CLONE_OK")
}
