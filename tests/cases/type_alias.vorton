// Test: type alias — type X = Y syntax sugar
type Pair = (Int, Str)

fn format_pair(p: Pair) -> Str {
    let (n, s) = p
    "${n}: ${s}"
}

fn main() {
    let p = (42, "hello")
    print(format_pair(p))
}

// expect: 42: hello
