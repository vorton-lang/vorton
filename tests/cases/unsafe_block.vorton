mod unsafe_mod requires {unsafe} {
    pub fn safe_wrapper() -> Int {
        unsafe {
            let x = 42
            x
        }
    }
}

fn main() {
    let result = unsafe_mod::safe_wrapper()
    print(result.to_str())
}
