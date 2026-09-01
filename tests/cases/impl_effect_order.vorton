// Caller defined BEFORE impl block — tests cross-order effect propagation (#42 fix)

struct ParseError { msg: Str }
struct Parser { input: Str }

// This function is defined BEFORE impl Parser, but calls Parser.parse() which has fail effect.
// Before the fix, the fail effect was invisible here (EMPTY_ROW from Pass 1).
fn use_parser(p: Parser) -> Int {
    p.parse() catch {
        ParseError { msg } => -1,
    }
}

impl Parser {
    fn parse(self) -> Int {
        if self.input == "" {
            fail.raise(ParseError { msg: "empty input" })
        }
        self.input.len()
    }
}

fn main() {
    let r1 = use_parser(Parser { input: "hello" })
    assert(r1 == 5, "expected 5 got ${r1.to_str()}")

    let r2 = use_parser(Parser { input: "" })
    assert(r2 == -1, "expected -1 for empty input")

    print("impl_effect_order: all tests passed")
}
