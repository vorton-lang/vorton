// Test: mut<T> marker effect — basic injection and local-variable exemption

fn modify_list(mut list: List<Int>) {
    list.push(42)
}

fn local_mutation() {
    // Local let mut should NOT produce mut effect
    let mut x = [1, 2, 3]
    x.push(4)
    assert(x.len() == 4, "local mutation works")
}

fn main() {
    let mut nums = [1, 2, 3]
    modify_list(nums)
    assert(nums.len() == 4, "list modified")
    assert(nums.get(3) == some(42), "element added")
    local_mutation()
    print("mut_effect_basic: all tests passed")
}
