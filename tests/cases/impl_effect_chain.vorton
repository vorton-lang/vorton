struct ParseError { msg: Str }
struct Validator { value: Int }

impl Validator {
    fn validate(self) -> Int {
        if self.value < 0 {
            fail.raise(ParseError { msg: "negative" })
        }
        self.value
    }
}

fn process(v: Validator) -> Int {
    v.validate() + 1
}

fn main() {
    let result = process(Validator { value: 10 }) catch {
        ParseError { msg } => -1,
    }
    assert(result == 11, "propagated effect works")

    let result2 = process(Validator { value: -1 }) catch {
        ParseError { msg } => -1,
    }
    assert(result2 == -1, "propagated effect catches error")

    print("impl_effect_chain: all tests passed")
}
