// B-100 P1.1 parity: impl effect propagation — cross-order (caller defined
// before impl block), intra-impl (caller before callee in same block),
// basic impl method fail propagation.

// --- Cross-order: caller defined before impl ---

struct ParseError { msg: Str }
struct Parser { input: Str }

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

// --- Intra-impl: caller before callee in same block ---

struct ValidationError { msg: Str }
struct Validator { value: Int }

impl Validator {
    fn validate(self) -> Int {
        self.check()
        self.value
    }

    fn check(self) {
        if self.value < 0 {
            fail.raise(ValidationError { msg: "negative" })
        }
    }
}

// --- Basic impl method fail propagation ---

struct MyError { msg: Str }
struct Processor { data: Str }

impl Processor {
    fn process(self) -> Int {
        if self.data == "" {
            fail.raise(MyError { msg: "empty data" })
        }
        42
    }
}

fn main() {
    // Cross-order: caller before impl
    let r1 = use_parser(Parser { input: "hello" })
    print("cross_ok=${r1}")
    let r2 = use_parser(Parser { input: "" })
    print("cross_fail=${r2}")

    // Intra-impl: caller before callee
    let v1 = Validator { value: 42 }
    let r3 = v1.validate() catch { ValidationError { msg } => -1 }
    print("intra_ok=${r3}")
    let v2 = Validator { value: -1 }
    let r4 = v2.validate() catch { ValidationError { msg } => -1 }
    print("intra_fail=${r4}")

    // Basic impl method fail propagation
    let r5 = Processor { data: "" }.process() catch { MyError { msg } => -1 }
    print("basic_fail=${r5}")
    let r6 = Processor { data: "hello" }.process() catch { _ => -1 }
    print("basic_ok=${r6}")
}
