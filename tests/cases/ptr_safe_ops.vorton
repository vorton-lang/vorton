mod safe_test requires {unsafe} {
    pub fn test_addr_from_addr() -> Int {
        unsafe {
            let p = alloc(1)
            p.write(77)
            let a = p.addr()
            let p2: Ptr<Int> = ptr_from_addr(a)
            let v = p2.read()
            dealloc(p, 1)
            v
        }
    }

    pub fn test_cast() -> Int {
        unsafe {
            let p = alloc(1)
            p.write(55)
            let q: Ptr<Bool> = p.cast()
            let r: Ptr<Int> = q.cast()
            let v = r.read()
            dealloc(p, 1)
            v
        }
    }
}

fn main() {
    print(safe_test::test_addr_from_addr().to_str())
    print(safe_test::test_cast().to_str())
}
