// B-100 P1.3 R2 adversarial combo: supertrait method + effect.
//
// Existing supertrait tests don't combine with effects. If a supertrait
// method carries an effect (io or fail), the evidence must be threaded
// through the supertrait dict lookup chain. This can break if the LLVM
// codegen looks up the wrong dict slot or forgets to forward evidence
// when dispatching through a supertrait.
//
// Exercises:
//   * Supertrait method with io effect — called through subtrait bound
//   * Subtrait method forwarding to an effectful supertrait method
//   * Multi-level supertrait chain with fail effect
//   * Generic fn with subtrait bound calling effectful supertrait method

trait Loggable {
    fn log_self(self) -> Str
}

trait Describable: Loggable {
    fn describe(self) -> Str
}

struct Server { host: Str, port: Int }

impl Loggable for Server {
    fn log_self(self) -> Str {
        let msg = "${self.host}:${self.port}"
        print("LOG: ${msg}")
        msg
    }
}

impl Describable for Server {
    fn describe(self) -> Str {
        let logged = self.log_self()
        "Server(${logged})"
    }
}

// Call supertrait method through subtrait bound
fn log_via_subtrait<T: Describable>(x: T) -> Str {
    x.log_self()
}

fn describe_and_log<T: Describable>(x: T) -> Str {
    let d = x.describe()
    let l = x.log_self()
    "${d} | ${l}"
}

// --- Multi-level with fail ---

trait Checkable {
    fn check(self) -> Bool
}

trait Validatable: Checkable {
    fn validate(self) -> Str with {fail<Str>}
}

struct Input { text: Str }

impl Checkable for Input {
    fn check(self) -> Bool { self.text.len() > 0 }
}

impl Validatable for Input {
    fn validate(self) -> Str with {fail<Str>} {
        if !self.check() { fail.raise("empty input") }
        "valid:${self.text}"
    }
}

fn check_via_subtrait<T: Validatable>(x: T) -> Bool {
    x.check()
}

fn validate_safe<T: Validatable>(x: T) -> Str {
    x.validate() catch { e => "err:${e}" }
}

fn main() {
    let s1 = Server { host: "localhost", port: 8080 }
    let s2 = Server { host: "prod", port: 443 }

    // Test 1: supertrait io method through subtrait bound
    let r1 = log_via_subtrait(s1)
    print("T1: ${r1}")

    // Test 2: describe calls log_self (supertrait from subtrait impl)
    let r2 = s2.describe()
    print("T2: ${r2}")

    // Test 3: both through generic dispatch
    let r3 = describe_and_log(Server { host: "dev", port: 3000 })
    print("T3: ${r3}")

    // Test 4: Validatable — success path
    let i1 = Input { text: "hello" }
    let r4 = validate_safe(i1)
    print("T4: ${r4}")

    // Test 5: Validatable — failure path
    let i2 = Input { text: "" }
    let r5 = validate_safe(i2)
    print("T5: ${r5}")

    // Test 6: supertrait method through subtrait bound — Checkable.check via Validatable
    let r6 = check_via_subtrait(Input { text: "hi" })
    print("T6: ${r6}")

    let r7 = check_via_subtrait(Input { text: "" })
    print("T7: ${r7}")

    print("adversarial_combo_supertrait_effect: done")
}
