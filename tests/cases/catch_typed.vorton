struct ParseError { msg: Str }

fn may_fail(x: Int) -> Int {
    if x > 0 { x } else { fail.raise(ParseError { msg: "bad" }) }
}

fn main() {
    let result = may_fail(-1) catch { ParseError { msg } => 99 }
    print(result)
}
