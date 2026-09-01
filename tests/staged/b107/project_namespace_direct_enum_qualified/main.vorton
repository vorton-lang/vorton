// Root decoys make an unqualified variant fallback observably wrong.
fn Hit(value: Int) -> Int { value + 100 }
fn Idle() -> Int { 99 }

pub mod facade {
    pub enum State {
        Hit(Int),
        Idle,
    }
}

fn score(value: facade::State) -> Int {
    match value {
        facade::State::Hit(number) => number,
        facade::State::Idle => 0,
    }
}

fn main() {
    print(score(facade::State::Hit(17)))
    print(score(facade::State::Idle))
}
