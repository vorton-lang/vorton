// T::Item qualified path in generic function body
trait Producer {
    type Item
    fn produce(self) -> Item
}

struct NumProducer {
    n: Int
}

impl Producer for NumProducer {
    type Item = Int
    fn produce(self) -> Int {
        self.n * 2
    }
}

fn use_producer<T: Producer>(p: T) -> T::Item {
    p.produce()
}

fn main() {
    let p = NumProducer { n: 21 }
    let result = use_producer(p)
    assert(result == 42, "use_producer should return 42")
    print("assoc type qualified: ok")
}
