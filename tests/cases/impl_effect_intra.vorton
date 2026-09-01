// Intra-impl method effect propagation — caller defined BEFORE callee in same impl block

struct ValidationError { msg: Str }
struct Validator { value: Int }

impl Validator {
    // validate calls check, which is defined AFTER validate in this impl block
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

fn main() {
    let v1 = Validator { value: 42 }
    let r1 = v1.validate() catch { ValidationError { msg } => -1 }
    assert(r1 == 42, "expected 42")

    let v2 = Validator { value: -1 }
    let r2 = v2.validate() catch { ValidationError { msg } => -1 }
    assert(r2 == -1, "expected -1 for negative value")

    print("impl_effect_intra: all tests passed")
}
