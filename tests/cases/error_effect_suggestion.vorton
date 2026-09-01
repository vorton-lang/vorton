// expect-error: E0403
// Test: unhandled effect should include handler suggestion
effect Logger {
    fn log(msg: Str) -> Unit
}

fn do_work() {
    Logger.log("hello")
}

fn main() {
    do_work()
}
