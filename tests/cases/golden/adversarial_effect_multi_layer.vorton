// B-100 P1.3: adversarial — multi-layer effect handlers.
// Handler A handles one effect while handler B handles another.
// Tests that evidence threading through multiple handler layers and
// resume value propagation are correct.

effect Config {
    fn get(key: Str) -> Str
}

effect Logger {
    fn log(msg: Str) -> Unit
}

fn work() -> Str with {Config, Logger} {
    let mode = Config.get("mode")
    Logger.log("got mode: ${mode}")
    let host = Config.get("host")
    Logger.log("got host: ${host}")
    "${mode}@${host}"
}

fn main() {
    // Test 1: outer handles Logger, inner handles Config
    let r1 = handle {
        handle {
            work()
        } with {
            Config.get(k) => {
                if k == "mode" { "dev" }
                else { "localhost" }
            },
        }
    } with {
        Logger.log(msg) => print("LOG1: ${msg}"),
    }
    print("T1: ${r1}")

    // Test 2: reverse order — outer handles Config, inner handles Logger
    let r2 = handle {
        handle {
            work()
        } with {
            Logger.log(msg) => print("LOG2: ${msg}"),
        }
    } with {
        Config.get(k) => {
            if k == "mode" { "prod" }
            else { "remote-host" }
        },
    }
    print("T2: ${r2}")

    // Test 3: same effect handled at two levels — inner shadows outer
    let r3 = handle {
        let a = Config.get("env")
        let b = handle {
            Config.get("env")
        } with {
            Config.get(k) => "inner-val",
        }
        "${a}+${b}"
    } with {
        Config.get(k) => "outer-val",
    }
    print("T3: ${r3}")

    print("adversarial_effect_multi_layer: done")
}
