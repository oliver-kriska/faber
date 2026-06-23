#!/usr/bin/env python3
"""Parity oracle — diff Faber's native scorer against the plugin's compute-metrics.py.

Reads Faber's export JSONL (parity/export.exs output: one session per line, with the source
.jsonl path + Faber's numbers), then runs the plugin reference scorer on the SAME raw files and
reports per-signal agreement. Both sides read identical raw transcripts, so any delta is a real
algorithmic difference — which we then attribute to the documented divergences.

    python3 parity/compare.py <faber_export.jsonl>

Override the reference path with PLUGIN_METRICS=/path/to/compute-metrics.py
"""
import importlib.util
import json
import os
import sys

PLUGIN = os.environ.get(
    "PLUGIN_METRICS",
    "/Users/oliverkriska/Projects/elixir-live-claude-engineer"
    "/.claude/skills/session-scan/references/compute-metrics.py",
)

SIGNALS = [
    "error_tool_ratio",
    "retry_loops",
    "user_corrections",
    "approach_changes",
    "context_compactions",
    "interrupted_requests",
]


def load_ref():
    spec = importlib.util.spec_from_file_location("ref_metrics", PLUGIN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ref_metrics(mod, path):
    data = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                data.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    sid = os.path.basename(path).replace(".jsonl", "")
    return mod.compute_session_metrics(data, sid, "parity")


def main():
    faber_jsonl = sys.argv[1]
    mod = load_ref()
    rows = [json.loads(line) for line in open(faber_jsonl) if line.strip()]

    sig_match = {s: 0 for s in SIGNALS}
    sig_total = {s: 0 for s in SIGNALS}
    fp_match = tier2_match = opp_match = score_close = 0
    n = 0
    divergences = []

    for row in rows:
        path = row["path"]
        try:
            m = ref_metrics(mod, path)
        except Exception as e:  # noqa: BLE001 - report and continue
            divergences.append(("ERROR", os.path.basename(path), str(e)))
            continue

        n += 1
        rs = m["friction_signals"]
        fs = row["signals"]
        diffs = []
        for s in SIGNALS:
            rv, fv = rs.get(s), fs.get(s)
            if s == "error_tool_ratio":
                ok = abs((rv or 0) - (fv or 0)) < 0.01
            else:
                ok = rv == fv
            sig_total[s] += 1
            if ok:
                sig_match[s] += 1
            else:
                diffs.append(f"{s}:{rv}->{fv}")

        if m["fingerprint"] == row["fingerprint"]:
            fp_match += 1
        else:
            diffs.append(f"fp:{m['fingerprint']}->{row['fingerprint']}")
        if bool(m["tier2_eligible"]) == bool(row["tier2"]):
            tier2_match += 1
        if abs(m["plugin_opportunity_score"] - row["opportunity"]) < 0.01:
            opp_match += 1
        if abs(m["friction_score"] - row["score"]) < 0.05:
            score_close += 1

        if diffs:
            divergences.append(("DIFF", os.path.basename(path)[:20], ", ".join(diffs)))

    denom = max(n, 1)
    print(f"\n=== PARITY: Faber native vs plugin compute-metrics.py, {n} sessions, same raw files ===\n")
    print("Per-signal exact-match rate:")
    for s in SIGNALS:
        t = sig_total[s] or 1
        print(f"  {s:22s} {sig_match[s]:3d}/{sig_total[s]:<3d}  {100 * sig_match[s] / t:5.1f}%")
    print()
    print(f"  fingerprint agreement   {fp_match:3d}/{denom:<3d}  {100 * fp_match / denom:5.1f}%")
    print(f"  tier2 agreement         {tier2_match:3d}/{denom:<3d}  {100 * tier2_match / denom:5.1f}%")
    print(f"  opportunity agreement   {opp_match:3d}/{denom:<3d}  {100 * opp_match / denom:5.1f}%")
    print(f"  friction_score +-0.05   {score_close:3d}/{denom:<3d}  {100 * score_close / denom:5.1f}%")

    print(f"\nDivergences ({len([d for d in divergences if d[0] == 'DIFF'])} sessions, ref->faber):")
    for kind, name, msg in divergences[:25]:
        print(f"  [{kind}] {name:20s} {msg}")


if __name__ == "__main__":
    main()
