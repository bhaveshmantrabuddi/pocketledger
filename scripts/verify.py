#!/usr/bin/env python3
"""Run the real Haskell -> Go HTTP <- Scala path using an isolated synthetic ledger."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
WINDOWS = os.name == "nt"


def go_binary():
    portable = ROOT / ".tools/go/bin" / ("go.exe" if WINDOWS else "go")
    return str(portable) if portable.exists() else shutil.which("go") or "go"


def run(command, cwd=ROOT):
    print("Running:", " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, check=True)


def check(condition, message):
    if not condition:
        raise AssertionError(message)


class LiveServer:
    def __init__(self, binary, folder):
        self.binary, self.folder = binary, folder
        self.process = None
        self.log = None

    def start(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.base = f"http://127.0.0.1:{self.port}"
        worker = ROOT / ".local/workers" / ("budget-engine.exe" if WINDOWS else "budget-engine")
        self.log = open(self.folder / "server.log", "a", encoding="utf-8")
        self.process = subprocess.Popen([
            str(self.binary), "-listen", f"127.0.0.1:{self.port}",
            "-db", str(self.folder / "ledger.db"),
            "-haskell-worker", str(worker), "-scala-jar", str(ROOT / ".local/workers/analytics.jar"),
        ], cwd=ROOT, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("API exited: " + (self.folder / "server.log").read_text(encoding="utf-8"))
            try:
                if self.request("GET", "/health")[0] == 200:
                    return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.1)
        raise RuntimeError("API did not become healthy")

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=10)
        if self.log:
            self.log.close()

    def request(self, method, path, payload=None):
        body = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(self.base + path, data=body, method=method,
                                         headers={"Content-Type": "application/json"})
        try:
            response = urllib.request.urlopen(request, timeout=25)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            data = response.read()
            return response.status, json.loads(data) if data else None


def integration(binary):
    (ROOT / ".local").mkdir(exist_ok=True)
    assertions = 0
    with tempfile.TemporaryDirectory(prefix="integration-", dir=ROOT / ".local") as temporary:
        server = LiveServer(binary, Path(temporary))
        try:
            server.start()
            status, health = server.request("GET", "/health")
            check(status == 200 and health["status"] == "ok", "Health check failed"); assertions += 1
            check(server.request("PUT", "/v1/budget", {"monthly_limit_cents": 10000})[0] == 200, "Budget update failed"); assertions += 1
            expenses = [
                {"id": str(uuid.uuid4()), "amount_cents": 1234, "category": "food", "note": "Synthetic lunch", "date": "2024-02-01"},
                {"id": str(uuid.uuid4()), "amount_cents": 4567, "category": "transport", "note": "Synthetic transit", "date": "2024-02-29"},
                {"id": str(uuid.uuid4()), "amount_cents": 800, "category": "food", "note": "Outside selected month", "date": "2024-03-01"},
            ]
            for expense in expenses:
                check(server.request("POST", "/v1/transactions", expense)[0] == 201, "Expense create failed"); assertions += 1
            check(server.request("POST", "/v1/transactions", expenses[0])[0] == 200, "Identical retry was not idempotent"); assertions += 1
            conflict = {**expenses[0], "amount_cents": 999}
            check(server.request("POST", "/v1/transactions", conflict)[0] == 409, "Conflicting replay accepted"); assertions += 1
            status, dashboard = server.request("GET", "/v1/dashboard?month=2024-02&as_of=2024-02-29")
            check(status == 200, "Real workers failed: " + repr(dashboard)); assertions += 1
            check(dashboard["calculation_sources"] == {"summary": "haskell", "analytics": "scala"}, "Wrong calculation sources"); assertions += 1
            summary = dashboard["summary"]
            check(summary["spent_cents"] == 5801 and summary["remaining_cents"] == 4199, "Budget arithmetic mismatch"); assertions += 1
            check(summary["days_in_month"] == 29 and summary["days_remaining"] == 0 and summary["daily_allowance_cents"] == 0, "Leap month-end handling mismatch"); assertions += 1
            analytics = dashboard["analytics"]
            check(sum(row["spent_cents"] for row in analytics["categories"]) == 5801, "Category conservation failed"); assertions += 1
            check(len(analytics["daily"]) == 29 and sum(row["spent_cents"] for row in analytics["daily"]) == 5801, "Daily conservation/gap filling failed"); assertions += 1
            check(analytics["largest"][0]["amount_cents"] == 4567, "Largest-expense ordering failed"); assertions += 1
            status, cutoff = server.request("GET", "/v1/dashboard?month=2024-02&as_of=2024-02-01")
            check(status == 200 and cutoff["summary"]["spent_cents"] == 1234, "Reporting cutoff failed"); assertions += 1
            check(cutoff["summary"]["projected_cents"] == 1234 * 29, "Pace projection failed"); assertions += 1
            for mutation in [{"amount_cents": 0}, {"amount_cents": 1.5}, {"date": "2025-02-29"}, {"category": "invalid"}, {"unexpected": True}]:
                invalid = {**expenses[0], "id": str(uuid.uuid4()), **mutation}
                check(server.request("POST", "/v1/transactions", invalid)[0] == 400, "Invalid record was accepted"); assertions += 1
            check(server.request("GET", "/v1/dashboard?month=2024-02&as_of=2024-03-01")[0] == 400, "Mismatched reporting date accepted"); assertions += 1
            server.stop(); server.start()
            status, persisted = server.request("GET", "/v1/transactions")
            check(status == 200 and len(persisted["transactions"]) == 3, "SQLite restart persistence failed"); assertions += 1
            check(server.request("GET", "/v1/budget")[1]["monthly_limit_cents"] == 10000, "Budget persistence failed"); assertions += 1
            for _ in range(2):
                check(server.request("DELETE", "/v1/transactions/" + expenses[0]["id"])[0] == 204, "Delete retry was not idempotent"); assertions += 1
            print(f"PASS: {assertions} live HTTP/cross-language integration assertions", flush=True)
            return assertions
        finally:
            server.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="Build workers, run their tests, and compile the API first")
    arguments = parser.parse_args()
    binary = ROOT / ".local/bin" / ("pocketledger.exe" if WINDOWS else "pocketledger")
    binary.parent.mkdir(parents=True, exist_ok=True)
    if arguments.build:
        if WINDOWS:
            run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "workers/build.ps1"])
        else:
            run(["sh", "workers/build.sh"])
    for worker in [ROOT / ".local/workers/analytics.jar", ROOT / ".local/workers" / ("budget-engine.exe" if WINDOWS else "budget-engine")]:
        if not worker.exists():
            raise SystemExit(f"Missing {worker.name}. Run python scripts/verify.py --build after installing the documented tools.")
    run([go_binary(), "build", "-o", str(binary), "./cmd/pocketledger"], cwd=ROOT / "server")
    run([sys.executable, "workers/test_protocol.py"])
    count = integration(binary)
    report = {"http_integration_assertions": count, "real_workers": ["haskell", "scala"], "platform": sys.platform}
    (ROOT / ".local/integration-result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
