// B-090: custom effect with a Unit-returning op whose handler body performs a
// side effect (print). Before B-090 the LLVM backend never dispatched the op, so
// the handler body never ran and its prints were silently dropped.
//
// Exercises: Unit op, handler-body side effects, op args threaded into the body,
// and ordering of multiple performs interleaved with the body's own prints.

effect Logger {
    fn log(msg: Str) -> Unit
}

fn do_work() {
    Logger.log("hello")
    print("between")
    Logger.log("world")
}

fn main() {
    handle {
        do_work()
    } with {
        Logger.log(msg) => print("LOG: ${msg}"),
    }
    print("done")
}
