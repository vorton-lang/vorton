struct Resource {
    name: Str
}

impl Drop for Resource {
    fn drop(self) {
        print("dropping ${self.name}")
    }
}

fn main() {
    let r = Resource { name: "file" }
    print("using resource")
    // scope end -> drop
}
