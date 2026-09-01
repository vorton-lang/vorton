impl<T: Eq> List {
    pub fn has_item(self, item: T) -> Bool {
        for x in self {
            if x == item { return true }
        }
        false
    }
}

fn main() {
    let nums = [1, 2, 3]
    assert(nums.has_item(2), "found 2")
    assert(!nums.has_item(5), "not found 5")
    print("impl_bounds: all tests passed")
}
