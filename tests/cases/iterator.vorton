// Test: Iterator and Iterable trait protocol

struct Counter { pub value: Int, pub max: Int }

impl Iterator for Counter {
    type Item = Int
    fn next(mut self) -> Int? {
        if self.value < self.max {
            let v = self.value
            self.value = self.value + 1
            some(v)
        } else {
            none
        }
    }
}

impl Iterable for Counter {
    type Item = Int
    type Iter = Counter
    fn iter(self) -> Counter { self }
}

fn main() {
    // Basic List iteration
    let items = [1, 2, 3]
    let mut sum = 0
    for x in items { sum = sum + x }
    assert(sum == 6, "list iteration")

    // Map iteration with destructuring
    let m = map_from([("a", 1), ("b", 2)])
    let mut key_count = 0
    for (k, v) in m { key_count = key_count + 1 }
    assert(key_count == 2, "map iteration")

    // Set iteration
    let s = set_from([10, 20, 30])
    let mut set_sum = 0
    for x in s { set_sum = set_sum + x }
    assert(set_sum == 60, "set iteration")

    // Range iteration (still works via special path)
    let mut range_sum = 0
    for i in 0..5 { range_sum = range_sum + i }
    assert(range_sum == 10, "range iteration")

    // Nested iteration (independent cursors)
    let list = [1, 2, 3]
    let mut pairs = 0
    for a in list {
        for b in list {
            pairs = pairs + 1
        }
    }
    assert(pairs == 9, "nested iteration independent cursors")

    // Custom Iterator
    let mut counter_sum = 0
    for x in (Counter { value: 0, max: 5 }) {
        counter_sum = counter_sum + x
    }
    assert(counter_sum == 10, "custom iterator")

    // Map iteration without destructuring
    let m2 = map_from([(1, 10), (2, 20)])
    let mut entry_count = 0
    for entry in m2 { entry_count = entry_count + 1 }
    assert(entry_count == 2, "map iteration without destructure")

    print("iterator: all tests passed")
}
