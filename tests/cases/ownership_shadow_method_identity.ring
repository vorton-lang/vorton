fn touch(mut value: Int) {
    value = value + 1
}

struct Marker {}

impl Marker {
    fn touch(self, value: Int) -> Int {
        value + 10
    }
}

trait Writer {
    fn write(self, mut value: Int)
}

impl Writer for Marker {
    fn write(self, mut value: Int) {
        value = value + 2
    }
}

fn main() {
    let marker = Marker {}
    let mut value = 1
    touch(value)
    print(value)
    print(marker.touch(value))
    marker.write(value)
    print(value)
}
