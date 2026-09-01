// B-090: custom effect, tail-resumptive handler whose op RETURNS a value the
// body then uses as the resume value. Before B-090 the LLVM backend stored null
// as evidence and gen_effect_op returned null, so the body received null where it
// expected the op's Str result → crash in str_from_cstr / wrong output.
//
// Exercises: single effect, multiple ops, op return values of Str + Int threaded
// back into the handle body and combined.

effect Config {
    fn get_name() -> Str
    fn get_count() -> Int
}

fn describe() -> Str {
    let name = Config.get_name()
    let count = Config.get_count()
    "${name}:${count.to_str()}"
}

fn main() {
    let result = handle {
        describe()
    } with {
        Config.get_name() => "app",
        Config.get_count() => 42,
    }
    print(result)                 // app:42
    print("len=${result.len().to_str()}")
}
