use lib::{Source, Numbers, raise_number, recover}

fn main() {
    let value = recover(
        Numbers {},
        fn() -> Int { raise_number() }
    )
    print(value)
}
