struct MyError { msg: Str }
struct Parser { input: Str }

impl Parser {
    fn parse(self) -> Int {
        if self.input == "" {
            fail.raise(MyError { msg: "empty input" })
        }
        42
    }
}

fn main() {
    let result = Parser { input: "" }.parse() catch {
        MyError { msg } => -1,
    }
    assert(result == -1, "fail effect propagated from impl method")

    let result2 = Parser { input: "hello" }.parse() catch {
        _ => -1,
    }
    assert(result2 == 42, "success case")

    print("impl_effect_propagation: all tests passed")
}
