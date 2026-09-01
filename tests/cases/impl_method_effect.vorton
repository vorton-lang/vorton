// B-139: E2E test for impl method effect propagation (B-138)
// Non-cyclic dependency: method A (source-order first) calls method B (source-order second),
// B has fail effect. After B-138 SCC ordering, A should correctly infer fail effect.

enum ParseError {
    BadInput { msg: Str },
}

struct Parser {
    input: Str,
}

impl Parser {
    // A is source-order FIRST but calls B (which is after)
    fn parse(self) -> Int {
        if self.input == "" {
            self.fail_parse("empty input")  // calls method below
        }
        42
    }

    // B has fail effect (raises ParseError)
    fn fail_parse(self, msg: Str) -> Never {
        fail.raise(ParseError::BadInput { msg: msg })
    }
}

fn main() {
    let p = Parser { input: "" }
    let result = p.parse() catch {
        ParseError::BadInput { msg } => -1,
    }
    assert(result == -1, "effect propagated from impl method B to A")

    let p2 = Parser { input: "hello" }
    let ok = p2.parse() catch {
        ParseError::BadInput { msg } => -1,
    }
    assert(ok == 42, "normal path works")

    print("caught: empty input")
    print("impl_method_effect: all tests passed")
}
