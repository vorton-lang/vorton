mod fx {
    pub effect Logger {
        fn log(msg: Str) -> Str
    }
}

// Test 1: Effect annotation with qualified path
fn use_logger() -> Str with {fx::Logger} {
    fx::Logger.log("hello")
}

// Test 2: Handle with qualified effect handler
fn custom_handle() -> Str {
    handle {
        fx::Logger.log("world")
    } with {
        fx::Logger.log(msg) => "custom: ${msg}"
    }
}

fn main() {
    let r1 = handle {
        use_logger()
    } with {
        fx::Logger.log(msg) => "handled: ${msg}"
    }
    assert(r1 == "handled: hello", "qualified effect handler should work")
    let r2 = custom_handle()
    assert(r2 == "custom: world", "custom handler should work")
    print("mod effect qualified: ok")
}
