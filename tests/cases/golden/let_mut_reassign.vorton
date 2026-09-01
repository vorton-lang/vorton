// B-100 P1.1 parity: let mut + variable mutability — basic let mut
// reassignment, struct field mutation, mut self method calls, compound
// assignment in loops.

struct Counter { value: Int }

impl Counter {
    fn get(self) -> Int { self.value }
    fn increment(mut self) { self.value = self.value + 1 }
    fn add(mut self, amount: Int) { self.value = self.value + amount }
}

struct Point { x: Int, y: Int }

fn main() {
    // Basic let mut reassignment
    let mut x = 1
    x = x + 1
    print("reassign=${x}")

    // Compound assignment
    let mut n = 10
    n += 5
    print("plus_eq=${n}")
    n -= 3
    print("minus_eq=${n}")

    // Reassignment with expression
    let mut m = 5
    m = m * 2 + 1
    print("expr=${m}")

    // Struct field mutation
    let mut p = Point { x: 1, y: 2 }
    p.x = 10
    p.y = 20
    print("field=${p.x + p.y}")

    // let mut list push
    let mut items: List<Int> = []
    items.push(1)
    items.push(2)
    items.push(3)
    print("list_len=${items.len()}")

    // Mut self method calls
    let mut c = Counter { value: 0 }
    c.increment()
    c.increment()
    c.add(10)
    print("counter=${c.get()}")

    // let mut in while loop
    let mut sum = 0
    let mut i = 1
    while i <= 5 {
        sum += i
        i += 1
    }
    print("while_sum=${sum}")

    // let mut in for loop
    let mut total = 0
    for j in 0..5 {
        total += j * 2
    }
    print("for_total=${total}")
}
