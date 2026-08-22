fn touch(mut value: Int) {
    value = value + 1
}

struct Marker {}

impl Marker {
    fn touch(self, value: Int) -> Option<Int> {
        some(value + 10)
    }
}

trait Writer {
    fn write(self, mut value: Int) -> Option<Int>
}

impl Writer for Marker {
    fn write(self, mut value: Int) -> Option<Int> {
        value = value + 2
        some(value)
    }
}

fn main() {
    let marker = Marker {}
    let mut value = 1
    touch(value)
    print(value)
    match marker.touch(value) {
        some(result) => print(result),
        none => print(-1),
    }
    match marker.write(value) {
        some(result) => print(result),
        none => print(-1),
    }
}
