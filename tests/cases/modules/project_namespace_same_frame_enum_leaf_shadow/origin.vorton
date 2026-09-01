pub enum PublicBeforePrivate {
    Shared(Int),
}

enum PrivateLast {
    Shared(Int),
}

pub enum FirstPublic {
    Layered(Int),
}

// A private direct declaration remains the local winner even when public enum
// leaves occur on both sides.  Publication must still advance independently
// from FirstPublic::Layered to LastPublic::Layered.
const Layered: Int = 41

pub enum LastPublic {
    Layered(Int),
}

pub fn local_private_leaf() -> Int {
    let value: PrivateLast = Shared(31)
    match value {
        PrivateLast::Shared(number) => number,
    }
}

pub fn exact_shared_members() -> Int {
    let first: PublicBeforePrivate = PublicBeforePrivate::Shared(7)
    let last: PrivateLast = PrivateLast::Shared(11)
    let first_score = match first {
        PublicBeforePrivate::Shared(number) => number,
    }
    let last_score = match last {
        PrivateLast::Shared(number) => number,
    }
    first_score + last_score
}

pub fn local_direct_value() -> Int {
    Layered
}

pub fn exact_layered_members() -> Int {
    let first: FirstPublic = FirstPublic::Layered(13)
    let last: LastPublic = LastPublic::Layered(17)
    let first_score = match first {
        FirstPublic::Layered(number) => number,
    }
    let last_score = match last {
        LastPublic::Layered(number) => number,
    }
    first_score + last_score
}

pub mod projected {
    pub enum ProjectedFirst {
        Mirrored(Int),
    }

    pub enum ProjectedLast {
        Mirrored(Int),
    }

    pub fn local_mirrored() -> Int {
        let value: ProjectedLast = Mirrored(47)
        match value {
            ProjectedLast::Mirrored(number) => number,
        }
    }

    pub fn exact_mirrored_members() -> Int {
        let first: ProjectedFirst = ProjectedFirst::Mirrored(19)
        let last: ProjectedLast = ProjectedLast::Mirrored(23)
        let first_score = match first {
            ProjectedFirst::Mirrored(number) => number,
        }
        let last_score = match last {
            ProjectedLast::Mirrored(number) => number,
        }
        first_score + last_score
    }
}
