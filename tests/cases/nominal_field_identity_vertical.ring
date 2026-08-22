struct Left { value: Int }
struct Right { value: Str }
struct Box<T> { value: T }
struct Empty {}

mod nested {
    pub struct Left { pub value: Int }
}

fn read_box<T>(box: Box<T>) -> T { box.value }

fn main() {
    let left = Left { value: 7 }
    let right = Right { value: "right" }
    let boxed = Box { value: 42 }
    let nested_left = nested::Left { value: 11 }
    let cell = Cell(9)
    let _empty = Empty {}
    print("${left.value}:${right.value}:${read_box(boxed)}")
    print("${nested_left.value}:${cell.get()}")
}
