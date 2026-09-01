// E0201: multi-segment relative path where intermediate module doesn't exist
mod outer {
    mod inner {
        use super::nonexistent::{foo}

        pub fn get_foo() -> Int { foo() }
    }
}

fn main() {
    let _ = outer::inner::get_foo()
}
