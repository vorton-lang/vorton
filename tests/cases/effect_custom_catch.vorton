// Custom effect with catch — verify catch only handles fail, not custom effects
effect Logger {
    fn log(msg: Str) -> Unit
}

fn risky_work() -> Int {
    Logger.log("starting")
    fail.raise("oops")
    42
}

fn main() {
    // catch handles fail, Logger still needs handle...with
    let result = handle {
        risky_work() catch { _ => -1 }
    } with {
        Logger.log(msg) => {},
    }
    assert(result == -1, "catch handles fail, custom effect handled separately")

    // catch with custom effect performing before fail
    let r2 = handle {
        Logger.log("before fail")
        let v = fail.raise("err") catch { e => 99 }
        Logger.log("after catch")
        v
    } with {
        Logger.log(msg) => {},
    }
    assert(r2 == 99, "catch + custom effect interleaved")

    print("effect_custom_catch: all tests passed")
}
