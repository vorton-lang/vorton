fn store_cell_value(cell: Cell<Str>) -> Unit {
    let prefix = "cell"
    let value = "${prefix}-storage"
    cell.set(value)
}

mod raw_storage requires {unsafe} {
    fn store_ptr_value(p: Ptr<Str>) -> Unit {
        unsafe {
            let prefix = "ptr"
            let value = "${prefix}-storage"
            p.write(value)
        }
    }

    pub fn roundtrip() -> Str {
        unsafe {
            let p: Ptr<Str> = alloc(1)
            self::store_ptr_value(p)
            let value = p.take()
            dealloc(p, 1)
            value
        }
    }
}

fn main() {
    let cell = Cell("seed")
    store_cell_value(cell)
    print(cell.get())
    print(raw_storage::roundtrip())
}
