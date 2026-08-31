struct Resource {
    id: Int,
    payload: Str
}

impl Drop for Resource {
    fn drop(self) {}
}

mod raw_ptr requires {unsafe} {
    fn copy_ptr(value: Ptr<Resource>) -> Ptr<Resource> {
        value
    }

    pub fn run() -> Int {
        unsafe {
            let original: Ptr<Resource> = alloc(1)
            original.write(Resource { id: 23, payload: "ptr" })
            let first = self::copy_ptr(original)
            let second = self::copy_ptr(original)
            let same_address = first.addr() == second.addr()
            let value = first.take()
            dealloc(second, 1)
            if same_address { value.id } else { -1 }
        }
    }
}

fn main() {
    assert(raw_ptr::run() == 23,
        "Ptr pointee Drop-ness must not make the pointer TypeResource")
    print("B_PTR_NEGATIVE_CONTROL_OK")
}
