mod outer {
    pub mod inner {
        pub fn value() -> Int { 1 }
    }
}

mod inner {
    pub fn value() -> Int { 2 }
}

fn main() {
    print(outer::inner::value() + inner::value())
}
