mod ptr_test requires {unsafe} {
    pub fn test_alloc_write_read() -> Int {
        unsafe {
            let p = alloc(1)
            p.write(42)
            let v = p.read()
            dealloc(p, 1)
            v
        }
    }

    pub fn test_take() -> Int {
        unsafe {
            let p = alloc(1)
            p.write(99)
            let v = p.take()
            dealloc(p, 1)
            v
        }
    }

    pub fn test_offset() -> Int {
        unsafe {
            let p = alloc(3)
            p.write(10)
            p.offset(1).write(20)
            p.offset(2).write(30)
            let sum = p.read() + p.offset(1).read() + p.offset(2).read()
            dealloc(p, 3)
            sum
        }
    }
}

fn main() {
    print(ptr_test::test_alloc_write_read().to_str())
    print(ptr_test::test_take().to_str())
    print(ptr_test::test_offset().to_str())
}
