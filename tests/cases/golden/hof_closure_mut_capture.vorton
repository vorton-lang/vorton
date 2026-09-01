// B-114 regression (LLVM mut-cell write-through via a HOF callback). A closure
// that writes THROUGH a captured `let mut` is handed to `.map()` / `.filter()`,
// invoked once per element inside the runtime HOF, then the captured value is
// read back in the outer scope. The B-091 mechanism must box the `let mut` into
// a shared heap cell so every per-element write lands in the same container, and
// the Perceus pass must NOT drop the captured cell across the HOF call boundary
// (that would be a UAF / lost write).

fn main() {
    // inline lambda passed to .map(): accumulate through the captured cell
    let mut sum = 0
    let doubled = [1, 2, 3, 4].map(fn(x) {
        sum = sum + x
        x * 2
    })
    print("${sum}")                          // 10
    print("${doubled.get(3).unwrap_or(0)}")  // 8

    // inline lambda passed to .filter(): count visits through the captured cell
    let mut visits = 0
    let evens = [1, 2, 3, 4, 5, 6].filter(fn(x) {
        visits = visits + 1
        x % 2 == 0
    })
    print("${visits}")        // 6
    print("${evens.len()}")   // 3

    // named closure passed to .map(): captured cell survives the call boundary
    let mut acc = 0
    let bump = fn(x: Int) -> Int {
        acc = acc + x
        x + 100
    }
    let mapped = [10, 20, 30].map(bump)
    print("${acc}")                          // 60
    print("${mapped.get(2).unwrap_or(0)}")   // 130

    // two HOF callbacks share ONE captured `let mut`; both writes accumulate
    let mut total = 0
    [1, 2, 3].map(fn(x) { total = total + x; x })
    [10, 20].filter(fn(x) { total = total + x; true })
    print("${total}")   // 36
}
