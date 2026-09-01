mod outer {
    pub mod inner {
        pub fn greet(name: Str) -> Str {
            "hello ${name}"
        }

        pub fn add(a: Int, b: Int) -> Int {
            a + b
        }
    }
}

fn main() {
    let msg = outer::inner::greet("world")
    assert(msg == "hello world", "nested mod call")

    let sum = outer::inner::add(1, 2)
    assert(sum == 3, "nested mod arithmetic")

    print("mod_nested_block: all tests passed")
}
