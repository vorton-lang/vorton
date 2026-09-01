// B-100 P1.3: adversarial — effect operations inside/through closures.
// Tests that closures capturing variables interact correctly with
// fail/catch and custom effects.

enum E { NotFound { key: Str } }

fn lookup(key: Str) -> Str with {fail<E>} {
    if key == "" { fail.raise(E::NotFound { key: "empty" }) }
    "val-${key}"
}

fn apply_pure(f: fn(Str) -> Str, x: Str) -> Str {
    f(x)
}

effect Config {
    fn get(key: Str) -> Str
}

fn read_with_prefix(prefix: Str) -> Str {
    let val = Config.get(prefix)
    "${prefix}=${val}"
}

fn main() {
    // Test 1: closure captures variable, no effects
    let prefix = "hello"
    let greet = fn(name: Str) -> Str {
        "${prefix} ${name}"
    }
    let r1 = greet("world")
    print("T1: ${r1}")

    // Test 2: higher-order — pass closure to another function
    let tag = "X"
    let tagger = fn(s: Str) -> Str {
        "${tag}:${s}"
    }
    let r2 = apply_pure(tagger, "test")
    print("T2: ${r2}")

    // Test 3: fail in function called from within context that has closures
    let r3 = lookup("good") catch { _ => "caught" }
    print("T3: ${r3}")

    let r4 = lookup("") catch { _ => "not-found" }
    print("T4: ${r4}")

    // Test 5: closure used after catch
    let r5 = lookup("ok") catch { _ => "default" }
    let fmt = fn(s: Str) -> Str { "fmt(${s})" }
    print("T5: ${fmt(r5)}")

    // Test 6: effect handler with closure-like capture in handler body
    let base = "prod"
    let r6 = handle {
        read_with_prefix("mode")
    } with {
        Config.get(k) => "${base}-${k}",
    }
    print("T6: ${r6}")

    // Test 7: multiple closures capturing different vars
    let a = "first"
    let b = "second"
    let fa = fn(x: Str) -> Str { "${a}-${x}" }
    let fb = fn(x: Str) -> Str { "${b}-${x}" }
    print("T7: ${fa("x")} ${fb("y")}")

    print("adversarial_effect_closure: done")
}
