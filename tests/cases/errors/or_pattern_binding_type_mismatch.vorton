enum MixedBindingChoice {
    Integer(Int),
    Text(Str),
}

fn classify(choice: MixedBindingChoice) -> Int {
    match choice {
        Integer(value) | Text(value) => 0,
    }
}

fn main() {
    print(classify(Integer(1)))
}
