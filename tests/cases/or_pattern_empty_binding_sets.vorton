enum EmptyBindingChoice {
    EmptyShape,
    PayloadShape(Int, Int),
}

fn classify(choice: EmptyBindingChoice) -> Int {
    match choice {
        EmptyShape | PayloadShape(_, _) => 1,
    }
}

fn main() {
    print(classify(EmptyShape))
    print(classify(PayloadShape(2, 3)))
}
