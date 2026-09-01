// B-100 P1.3 R3 adversarial: effect defined in mod, operation from outside,
// handler outside the mod.
//
// Exercises:
//   * Effect declared inside mod
//   * Effect operation called from outside mod with qualified path
//   * Multiple mod-qualified effects in one handle block
//   * Const in mod referenced in handler

mod fx {
    pub const TAG: Str = "[fx]"

    pub effect Log {
        fn log(msg: Str) -> Unit
    }

    pub effect Metric {
        fn record(name: Str, value: Int) -> Unit
    }
}

// Function that uses mod effects, expects external handler
fn do_work(n: Int) with {fx::Log, fx::Metric} {
    fx::Log.log("start ${n}")
    fx::Metric.record("count", n)
    fx::Log.log("done ${n}")
}

fn compute(a: Int, b: Int) with {fx::Log} {
    fx::Log.log("computing ${a}+${b}=${a + b}")
}

fn main() {
    // Test 1: handle both effects from outside the mod
    handle {
        do_work(42)
    } with {
        fx::Log.log(msg) => print("${fx::TAG} ${msg}"),
        fx::Metric.record(name, value) => print("metric: ${name}=${value}"),
    }

    // Test 2: handle single effect
    handle {
        compute(3, 7)
    } with {
        fx::Log.log(msg) => print("log2: ${msg}"),
    }

    // Test 3: different handler for same effect
    handle {
        do_work(10)
    } with {
        fx::Log.log(msg) => print("alt: ${msg}"),
        fx::Metric.record(name, value) => print("m: ${value}"),
    }
}
