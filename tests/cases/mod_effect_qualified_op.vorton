// Regression: cross-module qualified effect op call in infer_method_call
// Verifies fx::Logger.log("hello") resolves to the fx::Logger effect's log op

mod fx {
    pub effect Logger {
        fn log(msg: Str) -> Unit
    }
}

fn logged_action() with {fx::Logger} {
    fx::Logger.log("hello")
    fx::Logger.log("world")
}

fn main() {
    handle {
        logged_action()
    } with {
        fx::Logger.log(msg) => print(msg),
    }
}
