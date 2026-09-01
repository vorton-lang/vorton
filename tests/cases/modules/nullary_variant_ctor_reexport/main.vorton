use facade::{Pulse, Go}
use whole
use inline_defs

fn score(p: Pulse) -> Int {
    match p {
        Pulse::Ready => 1,
        Pulse::Waiting => 0,
    }
}

fn passthrough(p: Pulse) -> Pulse {
    p
}

fn status_score(status: Status) -> Int {
    match status {
        Status::Up => 1,
        Status::Down => 0,
    }
}

fn mode_score(mode: inline_facade::State) -> Int {
    match mode {
        inline_facade::State::Hot => 1,
        inline_facade::State::Cold => 0,
    }
}

fn main() {
    let ready = Pulse::Ready
    print(local_ready_value())
    print(local_probe::ready_value())
    print(score(Ready))
    print(score(ready))
    print(score(Pulse::Waiting))
    print(score(passthrough(Pulse::Ready)))
    print(score(Go))
    print(status_score(Status::Up))
    print(mode_score(inline_facade::State::Hot))
}
