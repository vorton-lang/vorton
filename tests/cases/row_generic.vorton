struct Cat { name: Str, lives: Int }
struct Dog { name: Str, breed: Str }

fn get_name(animal: {name: Str, ..r}) -> Str {
    animal.name
}

fn main() {
    let cat_name = get_name(Cat { name: "whiskers", lives: 9 })
    let dog_name = get_name(Dog { name: "rex", breed: "lab" })
    print("${cat_name}-${dog_name}")
}
