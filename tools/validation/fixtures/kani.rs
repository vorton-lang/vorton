#[kani::proof]
fn kani_positive() {
    let input: u8 = kani::any();
    kani::assume(input <= 2);

    let mut count = 0_u8;
    while count < input {
        count += 1;
    }

    assert_eq!(count, input);
}

#[kani::proof]
fn kani_negative() {
    let input: u8 = kani::any();
    kani::assume(input <= 2);

    assert!(input != 2, "intentional Kani counterexample");
}
