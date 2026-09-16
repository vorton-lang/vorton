#!/usr/bin/env python3
"""Reproduce the frozen semantic failures on their exact historical compilers."""

from __future__ import annotations

from collections import defaultdict
import sys

from common import (
    GuardError,
    ROOT,
    guard_identity,
    load_manifest,
    observe_case,
    prepare_probe,
    require_observation,
)


def main() -> int:
    baseline, dirty = guard_identity()
    print(f"GUARD_BASELINE={baseline} DIRTY={str(dirty).lower()} PURPOSE=historical-replay")
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for case in load_manifest():
        grouped[case["historical_sha"]].append(case)

    executed = 0
    for sha, cases in grouped.items():
        executable = prepare_probe(ROOT, sha, "history")
        for case in cases:
            observation = observe_case(executable, case)
            require_observation(case, observation, "historical")
            executed += 1
    print(
        f"SEMANTIC_GUARD_HISTORY=EXPECTED_FAILURES_REPRODUCED "
        f"BASELINE={baseline} REVISIONS={len(grouped)} CASES={executed}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GuardError as error:
        print(f"INFRASTRUCTURE_ERROR={error}", file=sys.stderr)
        raise SystemExit(1) from error
