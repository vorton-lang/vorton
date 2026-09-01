// M11: Custom effect declaration + handler (not just built-in io/fail/mut)
effect Logger {
    fn log(msg: Str) -> Unit
}

fn do_work() {
    Logger.log("hello")
    Logger.log("world")
}

fn main() {
    handle {
        do_work()
    } with {
        Logger.log(msg) => print(msg),
    }
}
