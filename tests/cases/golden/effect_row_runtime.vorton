// B-100 P1.1: effect row types with runtime handle — partial effect handling
// where a handler eliminates one effect but remaining effects propagate to
// the outer scope. Tests that effect row resolution and evidence threading
// are correct.

effect Config {
    fn get(key: Str) -> Str
}

effect Logger {
    fn log(msg: Str) -> Unit
}

fn read_and_log() -> Str with {Config, Logger} {
    let val = Config.get("mode")
    Logger.log("read: ${val}")
    val
}

fn use_config() -> Str with {Config} {
    let a = Config.get("host")
    let b = Config.get("port")
    "${a}:${b}"
}

fn main() {
    // Test 1: handle both effects
    let r1 = handle {
        handle {
            read_and_log()
        } with {
            Logger.log(msg) => print("LOG: ${msg}"),
        }
    } with {
        Config.get(k) => "val-${k}",
    }
    print("T1: ${r1}")

    // Test 2: nested handlers — inner handles Config, outer handles Logger
    handle {
        let r2 = handle {
            read_and_log()
        } with {
            Config.get(k) => "inner-${k}",
        }
        print("T2: ${r2}")
    } with {
        Logger.log(msg) => print("T2-LOG: ${msg}"),
    }

    // Test 3: single effect, multiple ops
    let r3 = handle {
        use_config()
    } with {
        Config.get(k) => {
            if k == "host" { "localhost" }
            else { "8080" }
        },
    }
    print("T3: ${r3}")

    // Test 4: nested same-effect handlers — inner shadows outer
    let r4 = handle {
        let outer = Config.get("env")
        let inner = handle {
            Config.get("env")
        } with {
            Config.get(k) => "dev",
        }
        "${outer}-${inner}"
    } with {
        Config.get(k) => "prod",
    }
    print("T4: ${r4}")

    print("effect_row_runtime: done")
}
