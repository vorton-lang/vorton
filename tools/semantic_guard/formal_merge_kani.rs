#![allow(unexpected_cfgs)]

#[path = "../../crates/vorton-compiler/src/checker/formal_merge.rs"]
mod formal_merge;

#[kani::proof]
fn semantic_guard_kani_merge_small_domain() {
    let first_left = usize::from(kani::any::<u8>());
    let first_right = usize::from(kani::any::<u8>());
    kani::assume(first_left <= 2);
    kani::assume(first_right <= 2);

    let mut classes = [0, 1, 2];
    let no_independent = [];
    assert!(formal_merge::merge_classes(
        &mut classes,
        &no_independent,
        first_left,
        first_right,
    ));

    let independent_left = usize::from(kani::any::<u8>());
    let independent_right = usize::from(kani::any::<u8>());
    let merge_left = usize::from(kani::any::<u8>());
    let merge_right = usize::from(kani::any::<u8>());
    kani::assume(independent_left <= 2);
    kani::assume(independent_right <= 2);
    kani::assume(merge_left <= 2);
    kani::assume(merge_right <= 2);
    kani::assume(classes[independent_left] != classes[independent_right]);

    let independent = [(independent_left, independent_right)];
    let before = classes;
    let left_class = before[merge_left];
    let right_class = before[merge_right];
    let expected = !(before[independent_left] == left_class
        && before[independent_right] == right_class
        || before[independent_left] == right_class && before[independent_right] == left_class);
    let accepted = formal_merge::merge_classes(&mut classes, &independent, merge_left, merge_right);

    assert!(accepted == expected, "bounded merge decision");
    if accepted {
        let kept = left_class.min(right_class);
        let discarded = left_class.max(right_class);
        let expected_0 = if before[0] == discarded {
            kept
        } else {
            before[0]
        };
        let expected_1 = if before[1] == discarded {
            kept
        } else {
            before[1]
        };
        let expected_2 = if before[2] == discarded {
            kept
        } else {
            before[2]
        };
        assert!(classes[0] == expected_0, "bounded merge extent 0");
        assert!(classes[1] == expected_1, "bounded merge extent 1");
        assert!(classes[2] == expected_2, "bounded merge extent 2");
    } else {
        assert!(classes[0] == before[0], "bounded rejection keeps class 0");
        assert!(classes[1] == before[1], "bounded rejection keeps class 1");
        assert!(classes[2] == before[2], "bounded rejection keeps class 2");
    }
    assert_ne!(
        classes[independent_left], classes[independent_right],
        "bounded merge preserves caller independence",
    );
}
