#!/usr/bin/env python3
"""Hold this client's wire vocabulary to the SDK's, and refuse a silent gap.

`eidolon_sdk/biz/contracts` is the wire vocabulary every Body speaks. It is
Python, it is not vendored, and it is not transmitted — so nothing about it
reaches this repository except by somebody copying a value into
`lib/src/protocol/eidolon_protocol.dart`.

## Why this exists

On 2026-08-17 this client wrote its session-control request as
`{"schema_v": 1, "type": "session_open"}`, which was correct. On 2026-08-26
the SDK added `SESSION_CONVERSATION_ID_FIELD` and made it required; the
firmware followed the same day. This client did not, and for twelve days it
published its microphone into a room while the Channel Provider discarded
every request it made — `normalize_conversation_id(None)` is null, and a null
there is dropped without a log line. It was found by comparing LiveKit's room
participants against a working benchmark room.

A mirror test already existed for both clients in the SDK. The firmware's
asserted `kSessionConversationIdField`; the Dart one asserted a hand-picked
list of six constants that did not include it. **A roll-call of constants
cannot catch the constant that was just added**, which is the same lesson
`device_foundation_lock_test.dart` records about a lock that covered thirteen
of fourteen files: a check that verifies a set it also chooses can always be
made to pass by choosing less.

## The rule

So the unit here is not a constant, it is a **vocabulary**. `mirror` declares
which vocabularies this client participates in, and every SDK constant in one
of them must carry a decision — mirrored to a named Dart constant, or
deliberately not mirrored with a reason. A new constant lands in neither
column and this fails, saying so. Nobody has to remember to add an assertion.

The reasons are load-bearing in the other direction too: a constant recorded
as not mirrored must not actually be used, so a decision cannot rot into a
lie while staying green.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LEDGER_PATH = REPO_ROOT / "wire_contract_mirror.json"
DART_PATH = REPO_ROOT / "lib/src/protocol/eidolon_protocol.dart"
SDK_CONTRACTS = Path("eidolon_sdk/biz/contracts/__init__.py")


class MirrorLedgerInvalid(RuntimeError):
    """The ledger cannot say what it is supposed to say."""


#: Stands in for a constant whose value is computed rather than literal.
#:
#: Such a name still entered the vocabulary and still needs a decision, so it
#: is inventoried; only the value comparison is skipped. Dropping it entirely
#: is what let the first draft report `CONTROL_OP_ALIASES` as "no longer in
#: the SDK" while it sat there in plain sight.
COMPUTED = object()


def sdk_constants(contracts: Path) -> dict[str, object]:
    """Module-level upper-case assignments, read as syntax rather than run.

    Parsed with `ast` instead of imported: importing would execute a package
    from another repository to learn six strings, and would fail for reasons
    that have nothing to do with the vocabulary.
    """

    tree = ast.parse(contracts.read_text(encoding="utf-8"))
    found: dict[str, object] = {}
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if not isinstance(target, ast.Name) or not target.id.isupper():
                continue
            try:
                found[target.id] = ast.literal_eval(node.value)
            except ValueError:
                found[target.id] = COMPUTED
    return found


_DART_CONST = re.compile(
    r"^const\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?P<value>'[^']*'|\d+)\s*;",
    re.MULTILINE,
)


def dart_constants(source: Path) -> dict[str, object]:
    text = source.read_text(encoding="utf-8")
    found: dict[str, object] = {}
    for match in _DART_CONST.finditer(text):
        raw = match.group("value")
        found[match.group("name")] = (
            raw[1:-1] if raw.startswith("'") else int(raw)
        )
    return found


def load_ledger() -> dict:
    ledger = json.loads(LEDGER_PATH.read_text(encoding="utf-8"))
    vocabularies = ledger.get("vocabularies")
    if not isinstance(vocabularies, list) or not vocabularies:
        raise MirrorLedgerInvalid(
            "the ledger declares no vocabularies, so it would demand nothing"
        )
    if not isinstance(ledger.get("constants"), dict):
        raise MirrorLedgerInvalid("the ledger records no decisions")
    return ledger


def in_scope(name: str, vocabularies: list[str]) -> bool:
    return any(
        name == prefix or name.startswith(f"{prefix}_") for prefix in vocabularies
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sdk-repo",
        type=Path,
        default=Path(
            os.environ.get("EIDOLON_SDK_REPO", str(REPO_ROOT.parent / "eidolon_sdk"))
        ),
    )
    args = parser.parse_args()

    contracts = args.sdk_repo / SDK_CONTRACTS
    if not contracts.is_file():
        print(f"{contracts} is not there: no SDK checkout to mirror", file=sys.stderr)
        return 2

    try:
        ledger = load_ledger()
    except MirrorLedgerInvalid as invalid:
        print(str(invalid), file=sys.stderr)
        return 1

    vocabularies: list[str] = ledger["vocabularies"]
    decisions: dict[str, dict] = ledger["constants"]
    sdk = sdk_constants(contracts)
    dart = dart_constants(DART_PATH)
    dart_source = DART_PATH.read_text(encoding="utf-8")
    lib_source = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted((REPO_ROOT / "lib").rglob("*.dart"))
    )

    failures: list[str] = []
    scoped = sorted(name for name in sdk if in_scope(name, vocabularies))

    # The assertion that would have caught the bug: a constant entered a
    # vocabulary this client speaks and nobody decided anything about it.
    for name in scoped:
        if name not in decisions:
            failures.append(
                f"{name} is new in a vocabulary this client participates in and the "
                f"ledger says nothing about it — mirror it, or record why not"
            )

    for name, decision in sorted(decisions.items()):
        if name not in sdk:
            failures.append(
                f"{name} is in the ledger and no longer in the SDK: the decision "
                f"describes a constant nobody has"
            )
            continue
        if not in_scope(name, vocabularies):
            failures.append(
                f"{name} is decided but outside every declared vocabulary, so "
                f"nothing keeps its neighbours honest"
            )
            continue
        mirrored = decision.get("dart")
        reason = decision.get("not_mirrored")
        if mirrored and reason:
            failures.append(f"{name} is both mirrored and not mirrored")
        elif mirrored:
            if sdk[name] is COMPUTED:
                failures.append(
                    f"{name} is computed in the SDK, so `{mirrored}` cannot be "
                    f"checked against it"
                )
            elif mirrored not in dart:
                failures.append(
                    f"{name} claims to be mirrored by `{mirrored}`, which "
                    f"{DART_PATH.name} does not declare"
                )
            elif dart[mirrored] != sdk[name]:
                failures.append(
                    f"{mirrored} is {dart[mirrored]!r} and {name} is "
                    f"{sdk[name]!r}"
                )
        elif reason:
            # A decision that has rotted into a lie: recorded as not mirrored
            # while the value is in fact spelled out somewhere in `lib/`. This
            # is what found the four values that were inline in three files.
            #
            # Only distinctive values are searched. `SESSION_END_ERROR` is
            # `"error"`, which occurs thirteen times in `lib/` for unrelated
            # reasons, and a check that cries wolf on it would be turned off.
            # A wire value that is a bare English word cannot be told from
            # ordinary code by looking, so this does not pretend to.
            value = sdk[name]
            distinctive = (
                isinstance(value, str)
                and (len(value) >= 8 or "." in value or "_" in value)
            )
            if distinctive and f"'{value}'" in lib_source:
                failures.append(
                    f"{name} is recorded as not mirrored ({reason}) but its value "
                    f"{value!r} is written in lib/ anyway"
                )
        else:
            failures.append(f"{name} has an empty decision")

    # A prefix that matches nothing is a typo, and a typo silently narrows what
    # must be decided. Not required to mirror anything, though: `EVENT` is a
    # vocabulary this client speaks none of, and watching it anyway is the
    # point — the day this client emits its first event, the constant it
    # reaches for is already in the ledger with a reason to overturn.
    for prefix in vocabularies:
        if not any(in_scope(name, [prefix]) for name in scoped):
            failures.append(f"vocabulary {prefix} matches no SDK constant")

    # The pattern is the other half of `SESSION_CONVERSATION_ID_MAX_LENGTH`,
    # and it is a `final`, not a `const`, so the scan above cannot see it.
    max_length = sdk.get("SESSION_CONVERSATION_ID_MAX_LENGTH")
    if isinstance(max_length, int) and "sessionConversationIdPattern" in dart_source:
        if f"{{1,{max_length}}}" not in dart_source:
            failures.append(
                f"sessionConversationIdPattern does not bound length at "
                f"{max_length}, which is what the SDK accepts"
            )

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(
        f"wire contract mirror: PASS "
        f"({len(scoped)} constants across {len(vocabularies)} vocabularies)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
