// B-100 P1.3 R2 adversarial combo: handle/with + generic fn + closure.
//
// Combines three features that each require implicit parameter threading:
// custom effect (evidence), generics (trait dict), and closures (env capture).
// The handle...with block wraps a call to a generic function that internally
// creates closures. All three kinds of implicit state must coexist.
//
// Exercises:
//   * handle block around generic function call
//   * Generic fn performing custom effect op inside a closure
//   * Multiple effect ops in a generic context
//   * Handler resume value used in generic computation

effect Env {
    fn get_var(name: Str) -> Str
}

fn lookup_var(name: Str) -> Str {
    Env.get_var(name)
}

fn format_with_env<T: Eq>(items: List<T>, label: Str) -> Str {
    let env_val = lookup_var(label)
    let count = items.len()
    "${env_val}:${count}"
}

fn map_with_env(names: List<Str>) -> List<Str> {
    // Closure that captures nothing but uses effect inside
    names.map(fn(name) {
        let val = lookup_var(name)
        "${name}=${val}"
    })
}

fn find_env_match(keys: List<Str>, target: Str) -> Str {
    for key in keys {
        let val = lookup_var(key)
        if val == target { return key }
    }
    "none"
}

fn main() {
    // Test 1: handle + generic fn — format_with_env
    let r1 = handle {
        format_with_env([1, 2, 3], "count_label")
    } with {
        Env.get_var(name) => "ENV(${name})",
    }
    print("T1: ${r1}")

    // Test 2: handle + closure inside generic fn — map_with_env
    let r2 = handle {
        map_with_env(["host", "port"])
    } with {
        Env.get_var(name) => match name {
            "host" => "localhost",
            "port" => "8080",
            _ => "unknown",
        },
    }
    print("T2: ${r2.join(", ")}")

    // Test 3: handle + generic fn + effect in loop — find_env_match
    let r3 = handle {
        find_env_match(["a", "b", "c"], "found_b")
    } with {
        Env.get_var(name) => match name {
            "b" => "found_b",
            _ => "nope",
        },
    }
    print("T3: ${r3}")

    // Test 4: handle + no match found
    let r4 = handle {
        find_env_match(["x", "y"], "missing")
    } with {
        Env.get_var(name) => "val_${name}",
    }
    print("T4: ${r4}")

    // Test 5: nested handle — inner and outer both provide Env
    let r5 = handle {
        let inner = handle {
            lookup_var("inner_key")
        } with {
            Env.get_var(name) => "inner:${name}",
        }
        let outer = lookup_var("outer_key")
        "${inner}|${outer}"
    } with {
        Env.get_var(name) => "outer:${name}",
    }
    print("T5: ${r5}")

    // Test 6: handle + generic fn with different types
    let r6 = handle {
        format_with_env(["a", "b", "c", "d"], "str_label")
    } with {
        Env.get_var(name) => "STR(${name})",
    }
    print("T6: ${r6}")

    print("adversarial_combo_handle_generic_closure: done")
}
