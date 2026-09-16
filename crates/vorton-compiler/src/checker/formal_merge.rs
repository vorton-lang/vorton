#![allow(unexpected_cfgs)]

#[cfg(verus_keep_ghost)]
use vstd::prelude::*;

#[cfg(verus_keep_ghost)]
verus! {

pub open spec fn pair_crosses(
    classes: Seq<usize>,
    pair: (usize, usize),
    left_class: usize,
    right_class: usize,
) -> bool
    recommends
        pair.0 < classes.len(),
        pair.1 < classes.len(),
{
    &&& classes[pair.0 as int] == left_class
        && classes[pair.1 as int] == right_class
    || classes[pair.0 as int] == right_class
        && classes[pair.1 as int] == left_class
}

pub open spec fn merge_allowed(
    classes: Seq<usize>,
    independent: Seq<(usize, usize)>,
    left: usize,
    right: usize,
) -> bool
    recommends
        left < classes.len(),
        right < classes.len(),
        forall|index: int| 0 <= index < independent.len() ==>
            independent[index].0 < classes.len() && independent[index].1 < classes.len(),
{
    forall|index: int| 0 <= index < independent.len() ==>
        !pair_crosses(
            classes,
            independent[index],
            classes[left as int],
            classes[right as int],
        )
}

pub open spec fn merged_label(
    label: usize,
    left_class: usize,
    right_class: usize,
) -> usize {
    if left_class < right_class && label == right_class {
        left_class
    } else if right_class < left_class && label == left_class {
        right_class
    } else {
        label
    }
}

pub open spec fn independent_relations_hold(
    classes: Seq<usize>,
    independent: Seq<(usize, usize)>,
) -> bool
    recommends
        forall|index: int| 0 <= index < independent.len() ==>
            independent[index].0 < classes.len() && independent[index].1 < classes.len(),
{
    forall|index: int| 0 <= index < independent.len() ==>
        classes[independent[index].0 as int] != classes[independent[index].1 as int]
}

}

#[cfg_attr(
    verus_keep_ghost,
    verus_spec(allowed =>
        requires
            left < classes@.len(),
            right < classes@.len(),
            forall|index: int| 0 <= index < independent@.len() ==>
                independent@[index].0 < classes@.len()
                    && independent@[index].1 < classes@.len(),
        ensures
            allowed == merge_allowed(classes@, independent@, left, right),
    )
)]
fn formal_merge_allowed(
    classes: &[usize],
    independent: &[(usize, usize)],
    left: usize,
    right: usize,
) -> bool {
    let left_class = classes[left];
    let right_class = classes[right];
    let mut index = 0;
    #[cfg_attr(
        verus_keep_ghost,
        verus_spec(
            invariant
                index <= independent.len(),
                left < classes@.len(),
                right < classes@.len(),
                left_class == classes@[left as int],
                right_class == classes@[right as int],
                forall|entry: int| 0 <= entry < independent@.len() ==>
                    independent@[entry].0 < classes@.len()
                        && independent@[entry].1 < classes@.len(),
                forall|prior: int| 0 <= prior < index ==>
                    !pair_crosses(classes@, independent@[prior], left_class, right_class),
            decreases
                independent.len() - index,
        )
    )]
    while index < independent.len() {
        let pair = independent[index];
        let first_class = classes[pair.0];
        let second_class = classes[pair.1];
        if first_class == left_class && second_class == right_class
            || first_class == right_class && second_class == left_class
        {
            return false;
        }
        index += 1;
    }
    true
}

#[cfg_attr(
    verus_keep_ghost,
    verus_spec(result =>
        ensures
            result == merged_label(label, left_class, right_class),
    )
)]
fn merge_label(label: usize, left_class: usize, right_class: usize) -> usize {
    if left_class < right_class && label == right_class {
        left_class
    } else if right_class < left_class && label == left_class {
        right_class
    } else {
        label
    }
}

#[cfg_attr(
    verus_keep_ghost,
    verus_spec(accepted =>
        requires
            left < old(classes)@.len(),
            right < old(classes)@.len(),
            forall|entry: int| 0 <= entry < independent@.len() ==>
                independent@[entry].0 < old(classes)@.len()
                    && independent@[entry].1 < old(classes)@.len(),
            independent_relations_hold(old(classes)@, independent@),
        ensures
            accepted == merge_allowed(old(classes)@, independent@, left, right),
            final(classes)@.len() == old(classes)@.len(),
            !accepted ==> final(classes)@ == old(classes)@,
            independent_relations_hold(final(classes)@, independent@),
            accepted ==> forall|index: int| 0 <= index < final(classes)@.len() ==>
                final(classes)@[index] == merged_label(
                    old(classes)@[index],
                    old(classes)@[left as int],
                    old(classes)@[right as int],
                ),
    )
)]
pub(super) fn merge_classes(
    classes: &mut [usize],
    independent: &[(usize, usize)],
    left: usize,
    right: usize,
) -> bool {
    let left_class = classes[left];
    let right_class = classes[right];
    if !formal_merge_allowed(classes, independent, left, right) {
        return false;
    }
    let mut index = 0;
    #[cfg_attr(
        verus_keep_ghost,
        verus_spec(
            invariant
                index <= classes.len(),
                classes@.len() == old(classes)@.len(),
                left_class == old(classes)@[left as int],
                right_class == old(classes)@[right as int],
                forall|prior: int| 0 <= prior < index ==>
                    classes@[prior] == merged_label(
                        old(classes)@[prior],
                        left_class,
                        right_class,
                    ),
                forall|remaining: int| index <= remaining < classes@.len() ==>
                    classes@[remaining] == old(classes)@[remaining],
            decreases
                classes.len() - index,
        )
    )]
    while index < classes.len() {
        classes[index] = merge_label(classes[index], left_class, right_class);
        index += 1;
    }
    true
}

#[cfg(verus_keep_ghost)]
fn main() {}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;
    use proptest::test_runner::{Config as ProptestConfig, RngSeed};

    use super::merge_classes;

    proptest! {
        #![proptest_config(ProptestConfig {
            cases: 128,
            failure_persistence: None,
            max_shrink_iters: 1_024,
            rng_seed: RngSeed::Fixed(0x0056_4f52_544f_4e74),
            ..ProptestConfig::default()
        })]

        #[test]
        fn semantic_guard_core_merge_preserves_declared_independence(
            raw_classes in prop::collection::vec(0_u8..8, 1..9),
            raw_independent in prop::collection::vec((0_u8..8, 0_u8..8), 0..24),
            raw_left in 0_usize..8,
            raw_right in 0_usize..8,
        ) {
            let mut classes = Vec::with_capacity(raw_classes.len());
            for (index, raw_class) in raw_classes.iter().enumerate() {
                let representative = raw_classes[..=index]
                    .iter()
                    .position(|candidate| candidate == raw_class)
                    .expect("the current value is present in its prefix");
                classes.push(representative);
            }
            let left = raw_left % classes.len();
            let right = raw_right % classes.len();
            let mut independent = Vec::new();
            for (raw_first, raw_second) in raw_independent {
                let first = usize::from(raw_first) % classes.len();
                let second = usize::from(raw_second) % classes.len();
                let pair = if first <= second {
                    (first, second)
                } else {
                    (second, first)
                };
                if classes[pair.0] != classes[pair.1] && !independent.contains(&pair) {
                    independent.push(pair);
                }
            }

            let before = classes.clone();
            let left_class = before[left];
            let right_class = before[right];
            let expected = !independent.iter().any(|(first, second)| {
                before[*first] == left_class && before[*second] == right_class
                    || before[*first] == right_class && before[*second] == left_class
            });
            let accepted = merge_classes(&mut classes, &independent, left, right);

            prop_assert_eq!(accepted, expected);
            if accepted {
                let kept = left_class.min(right_class);
                let discarded = left_class.max(right_class);
                for (before, after) in before.iter().zip(&classes) {
                    let expected = if *before == discarded { kept } else { *before };
                    prop_assert_eq!(*after, expected);
                }
                for (first, second) in independent {
                    prop_assert_ne!(classes[first], classes[second]);
                }
            } else {
                prop_assert_eq!(classes, before);
            }
        }
    }
}
