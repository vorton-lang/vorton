// expect-error: E0405
mod pure requires {} {
    struct Foo { x: Int }

    impl Foo {
        fn show(self) -> Unit with {console} {
            print("hello")
        }
    }
}
