fn greet(name: Str) -> Str {
    "hello ${name}"
}

fn concat(a: Str, b: Str) -> Str {
    "${a}${b}"
}

fn main() {
    let r1 = "${greet("world")}"
    assert(r1 == "hello world", "direct call in interp")

    let r2 = "result: ${concat("hello", "world")}"
    assert(r2 == "result: helloworld", "multi-arg call in interp")

    let x = "inner"
    let r3 = "outer(${greet("${x}")})"
    assert(r3 == "outer(hello inner)", "nested interp in fn call")

    print("string_interp_fn_call: all tests passed")
}
