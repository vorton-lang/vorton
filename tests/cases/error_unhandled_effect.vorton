// Negative test: unhandled custom effect in main should report E0403
effect Logger {
    fn log(msg: Str) -> Unit
}

fn do_work() {
    Logger.log("hello")
}

fn main() {
    // Logger effect is NOT handled — should report E0403
    do_work()
}
