#!/usr/bin/env python3
"""Durable debounce ledger for Repository Steward Audit rounds.

Records live in a dedicated Git notes ref, so they survive sessions without
changing the audited source commit, HEAD, or the worktree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


NOTE_REF = "refs/notes/vorton-steward-audit-ledger"
LEDGER_VERSION = 1
INVALID_INPUT_EXIT = 2
ALREADY_RECORDED_EXIT = 3
OUTCOMES = frozenset(("findings", "no-findings"))
AUDIT_LENSES = frozenset(
    (
        "rc-memory",
        "type-soundness",
        "backend-parity",
        "runtime-abi",
        "design-drift",
        "oracle-blind",
    )
)

TOKEN = re.compile(r"[a-z][a-z0-9._:/-]{1,127}")
SOURCE_SHA = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
ISO_DATE = re.compile(
    r"(?:^|[._:/-])(?:19|20)\d{2}"
    r"[._:/-]?(?:0[1-9]|1[0-2])"
    r"[._:/-]?(?:0[1-9]|[12]\d|3[01])"
    r"(?:$|[._:/-])"
)
UUID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}"
)
RANDOM_HEX = re.compile(r"(?:^|[._:/-])[0-9a-f]{16,}(?:$|[._:/-])")
INCREMENTAL_TRIGGER_SUFFIX = re.compile(
    r"(?:^|[._:/-])"
    r"(?:(?:round|run|retry|attempt|counter)[._:/-]?)?\d+$"
)
EVIDENCE_COMMIT = re.compile(
    r"evidence:commit:(?P<commit_sha>[0-9a-f]{40}|[0-9a-f]{64})"
)
DURABLE_REF_PREFIXES = (
    "refs/heads",
    "refs/remotes",
    "refs/tags",
)


class AuditLedgerError(RuntimeError):
    """Base class for ledger validation and Git failures."""


class InvalidLedgerInput(AuditLedgerError):
    """A caller supplied a non-canonical key or outcome."""


class CorruptLedger(AuditLedgerError):
    """The note exists but does not satisfy the ledger schema."""


class AlreadyRecorded(AuditLedgerError):
    """The canonical Audit key already has a durable outcome."""

    def __init__(self, record: dict[str, Any]) -> None:
        super().__init__("Audit round already recorded")
        self.record = record


@dataclass(frozen=True)
class EvidenceEvent:
    commit_sha: str


def parse_evidence_event(trigger_id: str) -> EvidenceEvent | None:
    """Parse the closed evidence:<kind>:<durable-id> namespace."""

    match = EVIDENCE_COMMIT.fullmatch(trigger_id)
    if match is None:
        return None
    return EvidenceEvent(commit_sha=match.group("commit_sha"))


def normalize_trigger_id(raw: str) -> str:
    """Normalize a stable trigger/event id and reject common bypass ids."""

    value = raw.strip().lower()
    if not TOKEN.fullmatch(value):
        raise InvalidLedgerInput(
            "trigger id must be 2-128 lowercase-safe characters and start "
            "with a letter"
        )
    if value.startswith("evidence:"):
        if parse_evidence_event(value) is None:
            raise InvalidLedgerInput(
                "evidence trigger must match "
                "evidence:commit:<full-sha>; external findings/issues must "
                "first become a durable evidence commit"
            )
        return value
    if ISO_DATE.search(value) or UUID.search(value) or RANDOM_HEX.search(value):
        raise InvalidLedgerInput(
            "trigger id must be stable; dates, UUIDs, and random hex ids "
            "cannot bypass Audit debounce"
        )
    if INCREMENTAL_TRIGGER_SUFFIX.search(value):
        raise InvalidLedgerInput(
            "trigger id must be stable; round/run/retry/attempt/counter "
            "suffixes cannot bypass Audit debounce"
        )
    return value


def normalize_source_sha(raw: str) -> str:
    value = raw.strip().lower()
    if not SOURCE_SHA.fullmatch(value):
        raise InvalidLedgerInput(
            "source SHA must be a full 40- or 64-character commit id"
        )
    return value


def normalize_lenses(raw_lenses: Sequence[str]) -> tuple[str, ...]:
    """Return a sorted, unique lens set from repeated/comma-separated input."""

    normalized: set[str] = set()
    for raw in raw_lenses:
        for item in raw.split(","):
            lens = item.strip().lower()
            if not lens:
                continue
            if not TOKEN.fullmatch(lens):
                raise InvalidLedgerInput(
                    f"invalid lens {item!r}; use stable lowercase-safe ids"
                )
            if lens not in AUDIT_LENSES:
                raise InvalidLedgerInput(
                    f"unknown Audit lens {item!r}; choose from "
                    f"{sorted(AUDIT_LENSES)!r}; put exemption subclasses "
                    "in the stable trigger/event id"
                )
            normalized.add(lens)
    if not normalized:
        raise InvalidLedgerInput("at least one Audit lens is required")
    return tuple(sorted(normalized))


@dataclass(frozen=True)
class AuditKey:
    trigger_id: str
    source_sha: str
    lenses: tuple[str, ...]

    @classmethod
    def create(
        cls,
        trigger_id: str,
        source_sha: str,
        lenses: Sequence[str],
    ) -> AuditKey:
        return cls(
            trigger_id=normalize_trigger_id(trigger_id),
            source_sha=normalize_source_sha(source_sha),
            lenses=normalize_lenses(lenses),
        )

    @property
    def canonical(self) -> str:
        return json.dumps(
            {
                "lenses": list(self.lenses),
                "source_sha": self.source_sha,
                "trigger_id": self.trigger_id,
            },
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        )

    @property
    def digest(self) -> str:
        return hashlib.sha256(self.canonical.encode("utf-8")).hexdigest()


def empty_document(source_sha: str) -> dict[str, Any]:
    return {
        "records": [],
        "source_sha": normalize_source_sha(source_sha),
        "version": LEDGER_VERSION,
    }


def _stored_audit_key(
    raw_trigger_id: str,
    raw_source_sha: str,
    raw_lenses: Sequence[str],
) -> AuditKey:
    """Load a prior schema-v1 key without applying newer admission rules."""

    trigger_id = raw_trigger_id.strip().lower()
    if not TOKEN.fullmatch(trigger_id):
        raise InvalidLedgerInput("stored trigger id is not canonical")
    return AuditKey(
        trigger_id=trigger_id,
        source_sha=normalize_source_sha(raw_source_sha),
        lenses=normalize_lenses(raw_lenses),
    )


def validate_document(
    document: Any, expected_source_sha: str
) -> dict[str, Any]:
    """Validate and canonicalize an existing note document."""

    expected_source_sha = normalize_source_sha(expected_source_sha)
    if not isinstance(document, dict):
        raise CorruptLedger("ledger note must be a JSON object")
    if document.get("version") != LEDGER_VERSION:
        raise CorruptLedger(
            f"unsupported ledger version: {document.get('version')!r}"
        )
    if document.get("source_sha") != expected_source_sha:
        raise CorruptLedger("ledger source_sha does not match note target")
    records = document.get("records")
    if not isinstance(records, list):
        raise CorruptLedger("ledger records must be a list")

    canonical_records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            raise CorruptLedger(f"record {index} must be an object")
        raw_lenses = record.get("lenses")
        if not isinstance(raw_lenses, list) or not all(
            isinstance(lens, str) for lens in raw_lenses
        ):
            raise CorruptLedger(f"record {index} has invalid lenses")
        try:
            key = _stored_audit_key(
                str(record.get("trigger_id", "")),
                str(record.get("source_sha", "")),
                raw_lenses,
            )
        except InvalidLedgerInput as error:
            raise CorruptLedger(
                f"record {index} has invalid key: {error}"
            ) from error
        if key.source_sha != expected_source_sha:
            raise CorruptLedger(
                f"record {index} targets a different source SHA"
            )
        if record.get("canonical_key") != key.canonical:
            raise CorruptLedger(
                f"record {index} canonical_key does not match its fields"
            )
        if record.get("key_digest") != key.digest:
            raise CorruptLedger(
                f"record {index} key_digest does not match canonical_key"
            )
        outcome = record.get("outcome")
        if outcome not in OUTCOMES:
            raise CorruptLedger(f"record {index} has invalid outcome")
        summary = record.get("summary")
        if summary is not None and not isinstance(summary, str):
            raise CorruptLedger(f"record {index} has invalid summary")
        if key.canonical in seen:
            raise CorruptLedger(f"record {index} duplicates an Audit key")
        seen.add(key.canonical)
        canonical_record = {
            "canonical_key": key.canonical,
            "key_digest": key.digest,
            "lenses": list(key.lenses),
            "outcome": outcome,
            "source_sha": key.source_sha,
            "trigger_id": key.trigger_id,
        }
        if summary is not None:
            canonical_record["summary"] = summary
        canonical_records.append(canonical_record)

    canonical_records.sort(key=lambda item: item["canonical_key"])
    return {
        "records": canonical_records,
        "source_sha": expected_source_sha,
        "version": LEDGER_VERSION,
    }


def find_record(
    document: dict[str, Any], key: AuditKey
) -> dict[str, Any] | None:
    canonical = validate_document(document, key.source_sha)
    for record in canonical["records"]:
        if record["canonical_key"] == key.canonical:
            return record
    return None


def check_start_gate(
    document: dict[str, Any],
    key: AuditKey,
) -> dict[str, Any] | None:
    """Return an exact record or reject an unanchored same-scope restart."""

    canonical = validate_document(document, key.source_sha)
    same_scope = False
    for record in canonical["records"]:
        if record["canonical_key"] == key.canonical:
            return record
        if tuple(record["lenses"]) == key.lenses:
            same_scope = True
    if same_scope and parse_evidence_event(key.trigger_id) is None:
        raise InvalidLedgerInput(
            "same source SHA and lens set already has an Audit record; "
            "a different trigger must use an anchored "
            "evidence:<kind>:<durable-id> event"
        )
    return None


def record_outcome(
    document: dict[str, Any],
    key: AuditKey,
    outcome: str,
    summary: str | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Pure state transition: add one outcome or reject a duplicate key."""

    canonical = validate_document(document, key.source_sha)
    existing = check_start_gate(canonical, key)
    if existing is not None:
        raise AlreadyRecorded(existing)
    if outcome not in OUTCOMES:
        raise InvalidLedgerInput(
            f"outcome must be one of {sorted(OUTCOMES)!r}"
        )

    normalized_summary: str | None = None
    if summary is not None:
        normalized_summary = summary.strip()
        if not normalized_summary:
            normalized_summary = None
        elif len(normalized_summary) > 1000:
            raise InvalidLedgerInput("summary must not exceed 1000 characters")

    record: dict[str, Any] = {
        "canonical_key": key.canonical,
        "key_digest": key.digest,
        "lenses": list(key.lenses),
        "outcome": outcome,
        "source_sha": key.source_sha,
        "trigger_id": key.trigger_id,
    }
    if normalized_summary is not None:
        record["summary"] = normalized_summary

    updated_records = [*canonical["records"], record]
    updated_records.sort(key=lambda item: item["canonical_key"])
    updated = {
        "records": updated_records,
        "source_sha": key.source_sha,
        "version": LEDGER_VERSION,
    }
    return updated, record


def serialize_document(document: dict[str, Any], source_sha: str) -> str:
    canonical = validate_document(document, source_sha)
    return json.dumps(
        canonical,
        ensure_ascii=True,
        indent=2,
        sort_keys=True,
    ) + "\n"


class GitAuditLedger:
    """Git-notes-backed storage for Audit outcomes."""

    def __init__(self, repository: str | Path) -> None:
        requested = Path(repository).resolve()
        result = self._run_at(
            requested,
            ("rev-parse", "--show-toplevel"),
        )
        self.repository = Path(result.stdout.strip()).resolve()

    @staticmethod
    def _run_at(
        repository: Path,
        arguments: Sequence[str],
        *,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=False,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            text=True,
        )
        if check and result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            raise AuditLedgerError(
                f"git {' '.join(arguments)} failed "
                f"({result.returncode}): {detail}"
            )
        return result

    def _git(
        self, arguments: Sequence[str], *, check: bool = True
    ) -> subprocess.CompletedProcess[str]:
        return self._run_at(self.repository, arguments, check=check)

    def resolve_source_sha(self, source_sha: str) -> str:
        canonical = normalize_source_sha(source_sha)
        self._git(("cat-file", "-e", f"{canonical}^{{commit}}"))
        resolved = self._git(
            ("rev-parse", "--verify", f"{canonical}^{{commit}}")
        ).stdout.strip().lower()
        if resolved != canonical:
            raise InvalidLedgerInput(
                "source SHA did not resolve to the same full commit id"
            )
        return canonical

    def _validate_evidence_anchor(self, key: AuditKey) -> None:
        event = parse_evidence_event(key.trigger_id)
        if event is None:
            return
        anchor_sha = self.resolve_source_sha(event.commit_sha)
        if anchor_sha == key.source_sha:
            raise InvalidLedgerInput(
                "evidence commit must differ from the audited source SHA"
            )
        ancestry = self._git(
            (
                "merge-base",
                "--is-ancestor",
                key.source_sha,
                anchor_sha,
            ),
            check=False,
        )
        if ancestry.returncode == 1:
            raise InvalidLedgerInput(
                "evidence commit must descend from the audited source SHA"
            )
        if ancestry.returncode != 0:
            detail = ancestry.stderr.strip() or ancestry.stdout.strip()
            raise AuditLedgerError(
                "git merge-base --is-ancestor failed "
                f"({ancestry.returncode}): {detail}"
            )
        reachable = self._git(
            (
                "for-each-ref",
                "--format=%(refname)",
                f"--contains={anchor_sha}",
                *DURABLE_REF_PREFIXES,
            )
        )
        durable_refs = tuple(
            ref
            for ref in reachable.stdout.splitlines()
            if ref.startswith(
                tuple(f"{prefix}/" for prefix in DURABLE_REF_PREFIXES)
            )
        )
        if not durable_refs:
            raise InvalidLedgerInput(
                "evidence commit must be reachable from refs/heads/*, "
                "refs/remotes/*, or refs/tags/*; refs/notes/*, reflogs, "
                "and dangling object-only commits are not durable anchors"
            )

    def _read_document(self, source_sha: str) -> dict[str, Any]:
        source_sha = self.resolve_source_sha(source_sha)
        listed = self._git(
            ("notes", f"--ref={NOTE_REF}", "list", source_sha),
            check=False,
        )
        if listed.returncode == 1 and not listed.stdout.strip():
            return empty_document(source_sha)
        if listed.returncode != 0:
            detail = listed.stderr.strip() or listed.stdout.strip()
            raise AuditLedgerError(
                f"git notes list failed ({listed.returncode}): {detail}"
            )
        shown = self._git(
            ("notes", f"--ref={NOTE_REF}", "show", source_sha)
        )
        try:
            document = json.loads(shown.stdout)
        except json.JSONDecodeError as error:
            raise CorruptLedger(
                f"ledger note for {source_sha} is not valid JSON: {error}"
            ) from error
        return validate_document(document, source_sha)

    def query(self, key: AuditKey) -> dict[str, Any] | None:
        source_sha = self.resolve_source_sha(key.source_sha)
        if source_sha != key.source_sha:
            raise InvalidLedgerInput("Audit key source SHA is not canonical")
        self._validate_evidence_anchor(key)
        return find_record(self._read_document(source_sha), key)

    def check_start(self, key: AuditKey) -> dict[str, Any] | None:
        source_sha = self.resolve_source_sha(key.source_sha)
        if source_sha != key.source_sha:
            raise InvalidLedgerInput("Audit key source SHA is not canonical")
        self._validate_evidence_anchor(key)
        return check_start_gate(self._read_document(source_sha), key)

    def can_start(self, key: AuditKey) -> bool:
        return self.check_start(key) is None

    def record(
        self,
        key: AuditKey,
        outcome: str,
        summary: str | None = None,
    ) -> dict[str, Any]:
        source_sha = self.resolve_source_sha(key.source_sha)
        self._validate_evidence_anchor(key)
        document = self._read_document(source_sha)
        updated, record = record_outcome(
            document,
            key,
            outcome,
            summary,
        )
        payload = serialize_document(updated, source_sha)
        self._git(
            (
                "notes",
                f"--ref={NOTE_REF}",
                "add",
                "-f",
                "-m",
                payload,
                source_sha,
            )
        )
        return record


def _run_git(
    repository: Path, arguments: Sequence[str]
) -> subprocess.CompletedProcess[str]:
    return GitAuditLedger._run_at(repository, arguments)


def _pure_state_self_test() -> None:
    source = "a" * 40
    if normalize_lenses(tuple(AUDIT_LENSES)) != tuple(
        sorted(AUDIT_LENSES)
    ):
        raise AssertionError("the six-lens closed set was not accepted")
    for stable in (
        "user:full-audit",
        "risk:runtime-abi-change",
        "queue-empty-maintenance",
    ):
        if normalize_trigger_id(stable) != stable:
            raise AssertionError(f"stable first-round trigger changed: {stable}")
    evidence_trigger = f"evidence:commit:{'b' * 40}"
    if normalize_trigger_id(evidence_trigger) != evidence_trigger:
        raise AssertionError("commit evidence trigger changed")
    evidence_event = parse_evidence_event(evidence_trigger)
    if evidence_event is None or evidence_event.commit_sha != "b" * 40:
        raise AssertionError("commit evidence trigger did not parse")

    key = AuditKey.create(
        "risk:runtime-abi-change",
        source,
        ("runtime-abi", "rc-memory", "runtime-abi"),
    )
    if key.lenses != ("rc-memory", "runtime-abi"):
        raise AssertionError("lens set was not sorted and deduplicated")
    document = empty_document(source)
    if find_record(document, key) is not None:
        raise AssertionError("new key unexpectedly exists")
    updated, record = record_outcome(document, key, "no-findings")
    if record["outcome"] != "no-findings":
        raise AssertionError("no-findings outcome was not preserved")
    if find_record(updated, key) is None:
        raise AssertionError("recorded key was not found")
    try:
        record_outcome(updated, key, "findings")
    except AlreadyRecorded:
        pass
    else:
        raise AssertionError("duplicate canonical key was accepted")

    for unanchored in ("risk:next-event", "risk:post-fix-batch"):
        candidate = AuditKey.create(unanchored, source, key.lenses)
        try:
            check_start_gate(updated, candidate)
        except InvalidLedgerInput:
            pass
        else:
            raise AssertionError(
                f"same-scope unanchored event was accepted: {unanchored}"
            )

    anchored = AuditKey.create(evidence_trigger, source, key.lenses)
    if check_start_gate(updated, anchored) is not None:
        raise AssertionError("new anchored evidence event was blocked")
    with_anchor, _ = record_outcome(updated, anchored, "findings")
    if check_start_gate(with_anchor, anchored) is None:
        raise AssertionError("exact anchored event was not durable")

    new_source = AuditKey.create(key.trigger_id, "b" * 40, key.lenses)
    if check_start_gate(empty_document(new_source.source_sha), new_source):
        raise AssertionError("ordinary trigger on new source SHA was blocked")
    new_lens = AuditKey.create(
        key.trigger_id,
        source,
        (*key.lenses, "oracle-blind"),
    )
    if check_start_gate(updated, new_lens):
        raise AssertionError("ordinary trigger on changed lens set was blocked")

    legacy_key = AuditKey(
        trigger_id="audit:round-2",
        source_sha=source,
        lenses=("rc-memory",),
    )
    legacy_document = {
        "records": [
            {
                "canonical_key": legacy_key.canonical,
                "key_digest": legacy_key.digest,
                "lenses": list(legacy_key.lenses),
                "outcome": "no-findings",
                "source_sha": source,
                "trigger_id": legacy_key.trigger_id,
            }
        ],
        "source_sha": source,
        "version": LEDGER_VERSION,
    }
    if not validate_document(legacy_document, source)["records"]:
        raise AssertionError("schema-v1 counter record lost compatibility")

    for invalid_lens in (
        "rc-memory.2026-07-29",
        "rc-memory.1",
        "made-up",
        "made-up-lens",
    ):
        try:
            normalize_lenses((invalid_lens,))
        except InvalidLedgerInput:
            continue
        raise AssertionError(f"dynamic/unknown lens was accepted: {invalid_lens}")
    for unstable in (
        "audit:2026-07-29",
        "audit:20260729",
        "audit.2026-07-29",
        "audit.20260729",
        "audit:2026/07/29",
        "audit:2026_07_29",
        "audit:2026.07.29",
        "550e8400-e29b-41d4-a716-446655440000",
        "audit:550e8400-e29b-41d4-a716-446655440000",
        "0123456789abcdef0123456789abcdef",
        "audit:deadbeefdeadbeefdeadbeef",
        "audit.deadbeefdeadbeefdeadbeef",
        "audit:round-2",
        "audit:counter-2",
        "audit:2",
        "queue-empty-round-99",
        "audit:run-3",
        "audit:retry-4",
        "audit:attempt-5",
    ):
        try:
            normalize_trigger_id(unstable)
        except InvalidLedgerInput:
            continue
        raise AssertionError(f"unstable trigger id was accepted: {unstable}")
    for invalid_evidence in (
        "evidence:finding:7",
        "evidence:issue:7",
        "evidence:pr:19",
        "evidence:backlog:b-166",
        "evidence:decision:d-004",
        f"evidence:artifact:{'f' * 64}",
        "evidence:finding:0",
        "evidence:issue:x",
        "evidence:ticket:7",
        "evidence:backlog:166",
        "evidence:decision:d-12",
        "evidence:commit:deadbeef",
        "evidence:artifact:deadbeef",
        "evidence:finding:7:extra",
    ):
        try:
            normalize_trigger_id(invalid_evidence)
        except InvalidLedgerInput:
            continue
        raise AssertionError(
            f"malformed evidence trigger was accepted: {invalid_evidence}"
        )


def _run_helper_cli(
    repository: Path,
    command: str,
    trigger_id: str,
    source_sha: str,
    lenses: Sequence[str],
    *,
    outcome: str | None = None,
) -> subprocess.CompletedProcess[str]:
    arguments = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--repo",
        str(repository),
        command,
        "--trigger-id",
        trigger_id,
        "--source-sha",
        source_sha,
    ]
    for lens in lenses:
        arguments.extend(("--lens", lens))
    if outcome is not None:
        arguments.extend(("--outcome", outcome))
    return subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        text=True,
    )


def _git_end_to_end_self_test() -> None:
    with tempfile.TemporaryDirectory(
        prefix="vorton-audit-ledger-"
    ) as temporary:
        repository = Path(temporary)
        _run_git(repository, ("init", "--quiet"))
        _run_git(repository, ("config", "user.name", "Vorton Audit Ledger Test"))
        _run_git(
            repository,
            ("config", "user.email", "audit-ledger@example.invalid"),
        )
        _run_git(
            repository,
            ("commit", "--allow-empty", "-m", "source-one", "--quiet"),
        )
        source_one = _run_git(
            repository, ("rev-parse", "HEAD")
        ).stdout.strip()
        key = AuditKey.create(
            "user:full-audit",
            source_one,
            ("type-soundness", "rc-memory"),
        )

        first_session = GitAuditLedger(repository)
        if not first_session.can_start(key):
            raise AssertionError("fresh canonical key was unexpectedly blocked")
        head_before_note = _run_git(
            repository, ("rev-parse", "HEAD")
        ).stdout.strip()
        first_session.record(key, "no-findings")
        head_after_note = _run_git(
            repository, ("rev-parse", "HEAD")
        ).stdout.strip()
        if head_after_note != head_before_note:
            raise AssertionError("Git notes record changed source HEAD")
        _run_git(repository, ("rev-parse", "--verify", NOTE_REF))

        restarted_session = GitAuditLedger(repository)
        if restarted_session.can_start(key):
            raise AssertionError(
                "session restart reopened a recorded no-findings round"
            )
        existing = restarted_session.query(key)
        if existing is None or existing["outcome"] != "no-findings":
            raise AssertionError("session restart lost no-findings outcome")
        try:
            restarted_session.record(key, "findings")
        except AlreadyRecorded:
            pass
        else:
            raise AssertionError("same canonical key was recorded twice")

        _run_git(
            repository,
            (
                "commit",
                "--allow-empty",
                "-m",
                "durable-evidence",
                "--quiet",
            ),
        )
        evidence_commit = _run_git(
            repository, ("rev-parse", "HEAD")
        ).stdout.strip()
        evidence_tree = _run_git(
            repository, ("rev-parse", f"{evidence_commit}^{{tree}}")
        ).stdout.strip()
        unrelated_commit = _run_git(
            repository,
            ("commit-tree", evidence_tree, "-m", "unrelated-evidence"),
        ).stdout.strip()
        unreferenced_descendant = _run_git(
            repository,
            (
                "commit-tree",
                evidence_tree,
                "-p",
                source_one,
                "-m",
                "object-only-evidence",
            ),
        ).stdout.strip()

        exact_check = _run_helper_cli(
            repository,
            "check",
            key.trigger_id,
            source_one,
            key.lenses,
        )
        if exact_check.returncode != ALREADY_RECORDED_EXIT:
            raise AssertionError(
                f"exact key check did not exit 3: {exact_check.returncode}"
            )
        for counter_trigger in (
            "audit:round-2",
            "audit:counter-2",
            "audit:2",
            "queue-empty-round-99",
        ):
            rejected = _run_helper_cli(
                repository,
                "check",
                counter_trigger,
                source_one,
                key.lenses,
            )
            if rejected.returncode != INVALID_INPUT_EXIT:
                raise AssertionError(
                    f"CLI accepted counter trigger {counter_trigger!r}: "
                    f"exit {rejected.returncode}"
                )
        for invalid_evidence in (
            "evidence:finding:7",
            f"evidence:artifact:{'f' * 64}",
            "evidence:ticket:7",
            "evidence:backlog:166",
            "evidence:commit:deadbeef",
        ):
            rejected = _run_helper_cli(
                repository,
                "check",
                invalid_evidence,
                source_one,
                key.lenses,
            )
            if rejected.returncode != INVALID_INPUT_EXIT:
                raise AssertionError(
                    f"CLI accepted evidence trigger {invalid_evidence!r}: "
                    f"exit {rejected.returncode}"
                )
        for label, invalid_anchor in (
            ("nonexistent", "c" * 40),
            ("same-source", source_one),
            ("unrelated", unrelated_commit),
            ("object-only", unreferenced_descendant),
        ):
            rejected = _run_helper_cli(
                repository,
                "check",
                f"evidence:commit:{invalid_anchor}",
                source_one,
                key.lenses,
            )
            if rejected.returncode != INVALID_INPUT_EXIT:
                raise AssertionError(
                    f"CLI accepted {label} evidence commit: "
                    f"exit {rejected.returncode}"
                )
        unanchored_check = _run_helper_cli(
            repository,
            "check",
            "risk:next-event",
            source_one,
            key.lenses,
        )
        if unanchored_check.returncode != INVALID_INPUT_EXIT:
            raise AssertionError(
                "same-scope unanchored check did not exit 2"
            )
        unanchored_record = _run_helper_cli(
            repository,
            "record",
            "risk:post-fix-batch",
            source_one,
            key.lenses,
            outcome="findings",
        )
        if unanchored_record.returncode != INVALID_INPUT_EXIT:
            raise AssertionError(
                "same-scope unanchored record did not exit 2"
            )

        anchored = AuditKey.create(
            f"evidence:commit:{evidence_commit}",
            source_one,
            key.lenses,
        )
        anchored_check = _run_helper_cli(
            repository,
            "check",
            anchored.trigger_id,
            source_one,
            anchored.lenses,
        )
        if anchored_check.returncode != 0:
            raise AssertionError(
                f"anchored evidence check failed: {anchored_check.returncode}"
            )
        anchored_record = _run_helper_cli(
            repository,
            "record",
            anchored.trigger_id,
            source_one,
            anchored.lenses,
            outcome="findings",
        )
        if anchored_record.returncode != 0:
            raise AssertionError(
                f"anchored evidence record failed: "
                f"{anchored_record.returncode}"
            )
        after_anchor = GitAuditLedger(repository)
        persisted_anchor = after_anchor.query(anchored)
        if (
            persisted_anchor is None
            or persisted_anchor["outcome"] != "findings"
        ):
            raise AssertionError("anchored evidence event was not durable")
        duplicate_anchor = _run_helper_cli(
            repository,
            "record",
            anchored.trigger_id,
            source_one,
            anchored.lenses,
            outcome="no-findings",
        )
        if duplicate_anchor.returncode != ALREADY_RECORDED_EXIT:
            raise AssertionError("duplicate evidence anchor did not exit 3")
        head_after_gate = _run_git(
            repository, ("rev-parse", "HEAD")
        ).stdout.strip()
        if head_after_gate != evidence_commit:
            raise AssertionError("Audit gate/anchor operations changed HEAD")

        source_two = evidence_commit
        new_source = AuditKey.create(
            key.trigger_id,
            source_two,
            key.lenses,
        )
        new_lens = AuditKey.create(
            key.trigger_id,
            source_one,
            (*key.lenses, "runtime-abi"),
        )
        for label, candidate in (
            ("source SHA", new_source),
            ("lens set", new_lens),
        ):
            if not restarted_session.can_start(candidate):
                raise AssertionError(f"new {label} was incorrectly blocked")

        restarted_session.record(new_lens, "no-findings")
        recorded_lens = restarted_session.query(new_lens)
        if recorded_lens is None:
            raise AssertionError("changed canonical lens set did not reopen")

        for invalid_lens in (
            "rc-memory.2026-07-29",
            "rc-memory.1",
            "made-up",
            "made-up-lens",
        ):
            rejected = _run_helper_cli(
                repository,
                "check",
                key.trigger_id,
                source_one,
                (invalid_lens,),
            )
            if rejected.returncode != INVALID_INPUT_EXIT:
                raise AssertionError(
                    f"CLI accepted lens {invalid_lens!r}: "
                    f"exit {rejected.returncode}, stdout={rejected.stdout!r}, "
                    f"stderr={rejected.stderr!r}"
                )

        if restarted_session.query(key) is None:
            raise AssertionError("adding another record erased the first key")
        final_head = _run_git(
            repository, ("rev-parse", "HEAD")
        ).stdout.strip()
        if final_head != source_two:
            raise AssertionError("new-source/lens operations changed HEAD")


def self_test_errors() -> list[str]:
    errors: list[str] = []
    for label, test in (
        ("pure state machine", _pure_state_self_test),
        ("temporary Git notes end-to-end", _git_end_to_end_self_test),
    ):
        try:
            test()
        except Exception as error:  # noqa: BLE001 - return stable test failure
            errors.append(f"{label}: {type(error).__name__}: {error}")
    return errors


def _key_from_arguments(
    ledger: GitAuditLedger, arguments: argparse.Namespace
) -> AuditKey:
    source_sha = ledger.resolve_source_sha(arguments.source_sha)
    return AuditKey.create(
        arguments.trigger_id,
        source_sha,
        arguments.lens,
    )


def _print_json(value: dict[str, Any]) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Record/query bounded Audit outcomes in "
            f"{NOTE_REF} without changing source HEAD"
        )
    )
    parser.add_argument(
        "--repo",
        default=".",
        help="repository or worktree path (default: current directory)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run pure and temporary-Git regression tests",
    )
    subparsers = parser.add_subparsers(dest="command")
    for command in ("check", "query", "record"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--trigger-id", required=True)
        subparser.add_argument("--source-sha", required=True)
        subparser.add_argument(
            "--lens",
            action="append",
            required=True,
            help="stable lens id; repeat or pass comma-separated values",
        )
        if command == "record":
            subparser.add_argument(
                "--outcome",
                choices=sorted(OUTCOMES),
                required=True,
            )
            subparser.add_argument("--summary")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.self_test:
        if arguments.command is not None:
            parser.error("--self-test cannot be combined with a command")
        errors = self_test_errors()
        if errors:
            print("audit ledger self-test failed:")
            for error in errors:
                print(f"- {error}")
            return 1
        print(
            "audit ledger self-test passed: "
            "pure state machine + temporary Git notes/CLI end-to-end"
        )
        return 0
    if arguments.command is None:
        parser.error("a command is required")

    try:
        ledger = GitAuditLedger(arguments.repo)
        key = _key_from_arguments(ledger, arguments)
        if arguments.command == "query":
            record = ledger.query(key)
            _print_json(
                {
                    "canonical_key": key.canonical,
                    "record": record,
                    "status": "recorded" if record else "unrecorded",
                }
            )
            return 0
        if arguments.command == "check":
            record = ledger.check_start(key)
            if record is not None:
                _print_json(
                    {
                        "canonical_key": key.canonical,
                        "record": record,
                        "status": "skip-recorded",
                    }
                )
                return ALREADY_RECORDED_EXIT
            _print_json(
                {
                    "canonical_key": key.canonical,
                    "status": "allowed",
                }
            )
            return 0

        try:
            record = ledger.record(
                key,
                arguments.outcome,
                arguments.summary,
            )
        except AlreadyRecorded as error:
            _print_json(
                {
                    "canonical_key": key.canonical,
                    "record": error.record,
                    "status": "skip-recorded",
                }
            )
            return ALREADY_RECORDED_EXIT
        _print_json(
            {
                "canonical_key": key.canonical,
                "record": record,
                "status": "recorded",
            }
        )
        return 0
    except AuditLedgerError as error:
        print(f"audit ledger error: {error}", file=sys.stderr)
        return INVALID_INPUT_EXIT


if __name__ == "__main__":
    sys.exit(main())
