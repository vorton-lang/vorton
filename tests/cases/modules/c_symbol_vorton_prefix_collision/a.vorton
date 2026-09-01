struct Marker {
    value: Int,
}

impl Drop for Marker {
    fn drop(self) {
        print("drop a")
    }
}

pub fn run() {
    let marker = Marker { value: 1 }
    print("body a")
}
