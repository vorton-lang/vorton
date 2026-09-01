// B-100 P1.1: impl method effect propagation — fail effect raised in one
// impl method propagates through another impl method that calls it, and
// can be caught at the call site. Tests B-138 impl SCC ordering parity
// correctly.

struct ParseError { msg: Str }

struct Parser { input: Str }

impl Parser {
    fn parse(self) -> Int {
        if self.input == "" {
            fail.raise(ParseError { msg: "empty" })
        }
        if self.input == "bad" {
            fail.raise(ParseError { msg: "invalid" })
        }
        42
    }

    fn parse_and_format(self) -> Str {
        let n = self.parse()
        "result=${n.to_str()}"
    }

    fn parse_twice(self) -> Int {
        let a = self.parse()
        let b = self.parse()
        a + b
    }
}

fn use_parser(input: Str) -> Str {
    let p = Parser { input: input }
    p.parse_and_format()
}

fn main() {
    // Test 1: success path through impl chain
    let r1 = use_parser("hello") catch { ParseError { msg } => "err: ${msg}" }
    print("T1: ${r1}")

    // Test 2: failure propagates through parse_and_format -> parse
    let r2 = use_parser("") catch { ParseError { msg } => "err: ${msg}" }
    print("T2: ${r2}")

    // Test 3: direct impl method call with catch
    let p = Parser { input: "ok" }
    let r3 = p.parse() catch { _ => -1 }
    print("T3: ${r3.to_str()}")

    // Test 4: failure in direct call
    let p2 = Parser { input: "bad" }
    let r4 = p2.parse() catch { ParseError { msg } => -1 }
    print("T4: ${r4.to_str()}")

    // Test 5: parse_twice — double method call within impl
    let p3 = Parser { input: "valid" }
    let r5 = p3.parse_twice() catch { _ => -1 }
    print("T5: ${r5.to_str()}")

    // Test 6: parse_twice on empty — first call fails
    let p4 = Parser { input: "" }
    let r6 = p4.parse_twice() catch { ParseError { msg } => -1 }
    print("T6: ${r6.to_str()}")

    print("impl_effect_chain: done")
}
