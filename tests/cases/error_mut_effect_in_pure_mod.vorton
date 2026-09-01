// expect-error: E0405
// mut<T> marker effect should be blocked by mod requires {}

mod pure requires {} {
    pub fn modify(mut list: List<Int>) {
        list.push(1)
    }
}
