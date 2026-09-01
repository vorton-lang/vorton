fn transform<T, U>(items: List<T>, f: fn(T) -> U) -> List<U> {
    let mut result: List<U> = []
    for item in items {
        result.push(f(item))
    }
    result
}

fn main() {
    let nums = [1, 2, 3]
    let strs = transform(nums, fn(x) { x.to_str() })
    assert(strs.len() == 3, "transform length")
    assert(strs.get(0).unwrap() == "1", "transform first")
    print("fn_type_effect_poly: all tests passed")
}
