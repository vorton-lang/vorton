fn main() {
    let nums = [1, 2, 3]
    
    // map with side effect callback (io effect propagated through HOF)
    let mut count = 0
    let doubled = nums.map(fn(x) {
        count = count + 1
        x * 2
    })
    assert(doubled.len() == 3, "map result length")
    assert(count == 3, "side effect in map callback")
    
    // filter with side effect callback
    let mut checked = 0
    let evens = [1, 2, 3, 4].filter(fn(x) {
        checked = checked + 1
        x % 2 == 0
    })
    assert(evens.len() == 2, "filter result")
    assert(checked == 4, "side effect in filter callback")
    
    // fold with side effect callback
    let mut steps = 0
    let sum = [10, 20, 30].fold(0, fn(acc, x) {
        steps = steps + 1
        acc + x
    })
    assert(sum == 60, "fold result")
    assert(steps == 3, "side effect in fold callback")
    
    // nested: map inside fold
    // [1,2].fold(0, fn(acc,x) { [x, x*10].map(fn(y){y+1}).fold(0, fn(a,b){a+b}) + acc })
    // x=1: [1,10].map -> [2,11], fold -> 13. acc=0+13=13
    // x=2: [2,20].map -> [3,21], fold -> 24. acc=13+24=37
    let nested = [1, 2].fold(0, fn(acc, x) {
        let mapped = [x, x * 10].map(fn(y) { y + 1 })
        acc + mapped.fold(0, fn(a, b) { a + b })
    })
    assert(nested == 37, "nested HOF")
    
    print("trait_hof_effect: all tests passed")
}
