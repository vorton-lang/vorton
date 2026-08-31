effect Logger {
    fn log(msg: Str) -> Unit
}

effect alias IO = {console, fail<Str>}
effect alias Logging = {Logger}
effect alias Combined = {console, Logger}

fn greet(name: Str) -> Str with {IO} {
    print("Hello, ${name}")
    "done"
}

fn do_work() with {Combined} {
    print("working")
}

fn main() {
    let result = greet("world") catch { e => "error: ${e}" }
    assert(result == "done", "greet should return done")
    print("Effect alias: all passed")
}
