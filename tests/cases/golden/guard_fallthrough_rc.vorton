// RC fall-through regression (B-083). An OUTER heap-allocated variable (a List)
// is read inside an early arm's guard, then — because that guard is false — the
// match falls through to a LATER arm that uses the SAME variable again.
//
// If the Perceus pass modelled only the guard-true edge it would treat the
// guard's use of `xs` as a last-use and MOVE it, freeing the List before the
// later arm reads it -> use-after-free / wrong output under the native backend.
// The fix keeps `xs` alive across the guard fork (dup, not move) so the later
// arm still sees a valid List. The golden .expected pins the expected output;
// the native backend must match it.
fn sum(xs: List<Int>) -> Int {
    let mut total = 0
    for x in xs { total = total + x }
    total
}

fn pick(tag: Int, xs: List<Int>) -> Str {
    match tag {
        // For tag==1 this guard is FALSE (len is small), so we fall through to
        // the tag==1 arm below, which reads xs again. The first arm's guard must
        // not have consumed xs.
        1 if sum(xs) > 1000 => "tag1 big",
        1 => "tag1 fallthrough sum=${sum(xs)} len=${xs.len()}",
        2 if xs.len() == 0 => "tag2 empty",
        2 => "tag2 nonempty len=${xs.len()} sum=${sum(xs)}",
        _ => "other len=${xs.len()}"
    }
}

fn main() {
    let a = [10, 20, 30]
    print(pick(1, a))          // tag1 fallthrough sum=60 len=3
    let b = [1, 2, 3, 4]
    print(pick(2, b))          // tag2 nonempty len=4 sum=10
    let c: List<Int> = []
    print(pick(2, c))          // tag2 empty
    let d = [7, 8]
    print(pick(9, d))          // other len=2
}
