fn write(mut value: Int) {
    value = value + 1
}

trait Writer {
    fn write(self) -> Int
}

struct Inner {}

impl Writer for Inner {
    fn write(self) -> Int {
        10
    }
}

struct Outer {
    inner: Inner
}

impl Outer {
    delegate inner: Writer
}

fn main() {
    let outer = Outer { inner: Inner {} }
    let mut value = 0
    write(value)
    print(value)
    print(outer.write())
}
