"""Black-box checks of the actual executables; Python standard library only."""
from pathlib import Path
import argparse
import copy
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve().parent


def run(command, raw, valid=True):
    result = subprocess.run(command, input=raw, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=20)
    if valid:
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        assert not result.stderr, "unexpected diagnostic for valid input"
        return json.loads(result.stdout)
    assert result.returncode != 0, "invalid input accepted"
    assert result.stderr, "invalid input needs a diagnostic"
    assert not result.stdout, "errors must not write stdout"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--haskell", default=str(ROOT / (".local/workers/budget-engine.exe" if os.name == "nt" else ".local/workers/budget-engine")))
    parser.add_argument("--scala", default=str(ROOT / ".local/workers/analytics.jar"))
    parser.add_argument("--java", default="java")
    args = parser.parse_args()
    commands = [[args.haskell], [args.java, "-jar", args.scala]]
    base = json.loads((HERE / "fixtures/reporting.json").read_text())
    checked = 0
    for name in ["reporting", "leap-month-end"]:
        raw = (HERE / f"fixtures/{name}.json").read_bytes()
        expected = json.loads((HERE / f"fixtures/{name}.budget.expected.json").read_text())
        assert run(commands[0], raw) == expected
        analytics = run(commands[1], raw)
        assert analytics == json.loads((HERE / f"fixtures/{name}.analytics.expected.json").read_text())
        assert len(analytics["daily"]) == expected["elapsed_days"]
        assert sum(c["spent_cents"] for c in analytics["categories"]) == expected["spent_cents"]
        assert sum(d["spent_cents"] for d in analytics["daily"]) == expected["spent_cents"]
        assert analytics["largest"][0]["amount_cents"] == expected["spent_cents"]
        checked += 2
    bad_documents = []
    unicode_request = copy.deepcopy(base)
    unicode_request["transactions"][0]["note"] = 'Coffee 😀 price 1.5e2 and \\"quoted"'
    unicode_analytics = run(commands[1], json.dumps(unicode_request, ensure_ascii=False).encode())
    assert unicode_analytics["largest"][0]["note"] == unicode_request["transactions"][0]["note"]
    checked += 1
    for field, value in [("amount_cents", 0), ("amount_cents", 100000001),
                         ("amount_cents", 1.25), ("amount_cents", "100"),
                         ("category", "invalid"), ("id", "not-a-uuid"),
                         ("date", "2100-02-29"), ("date", "1999-12-31"),
                         ("note", "😀" * 141)]:
        invalid = copy.deepcopy(base)
        invalid["transactions"][0][field] = value
        bad_documents.append(json.dumps(invalid).encode())
    invalid = copy.deepcopy(base)
    invalid["transactions"].append(invalid["transactions"][0])
    bad_documents.append(json.dumps(invalid).encode())
    invalid = copy.deepcopy(base)
    invalid["as_of"] = "2026-11-01"
    bad_documents.append(json.dumps(invalid).encode())
    invalid = copy.deepcopy(base)
    invalid["monthly_limit_cents"] = 0
    bad_documents.append(json.dumps(invalid).encode())
    invalid = copy.deepcopy(base)
    invalid["extra"] = True
    bad_documents.extend([json.dumps(invalid).encode(), b"{", b"{}{}"])
    for literal in ["1.0", "1e0", "1e2", "1.0000000000000000001"]:
        bad_documents.append(json.dumps(base).replace('"amount_cents": 1250', f'"amount_cents": {literal}').encode())
    for command in commands:
        for raw in bad_documents:
            run(command, raw, valid=False)
            checked += 1
    print(f"Worker protocol: {checked} actual subprocess cases passed")


if __name__ == "__main__":
    main()
