# Plan: M2 breadth — fingerprint, opportunity, sidechain dedup

Complete the M2 session-scan port: classify each session (fingerprint), score missed
automation opportunities, dedup sidechain/subagent transcripts, and surface it all through
`Faber.Scan` + `mix faber.scan`. Faithful port of `compute-metrics.py`
(`compute_fingerprint`, `compute_plugin_opportunity`), engine-generic.

Verify per task: `mix compile --warnings-as-errors`. Per phase: `mix test <affected>`.
Final gate: full `mix test` + real-data smoke run. Commit per phase.

## Phase 1 — Fingerprint classifier
- [x] [P1-T1] Detect.fingerprint/1 — keyword scores + tool/files/tidewave/deps/PR bonuses, confidence = best/total; helpers bash_commands/files_edited
- [x] [P1-T2] tool_profile/1 gains :tidewave category; fingerprint + tidewave tests (inline normalized events)

## Phase 2 — Plugin-opportunity score
- [x] [P2-T1] Detect.opportunity/1 — score + missed list + used-skill detection (Skill calls, attributionSkill, /ns:cmd text); faithful port incl. separate first-2-token retry heuristic
- [x] [P2-T2] opportunity tests (investigate/verify/review/plan + used-skill exclusion + empty)

## Phase 3 — Scan integration + sidechain dedup
- [x] [P3-T1] Extend `Faber.Scan.Result` with fingerprint + opportunity; tier-2 = friction>0.35 OR opportunity>0.5 OR skills-used OR msgs>50
- [x] [P3-T2] Sidechain dedup in `Faber.Scan.run/1` — group by session_id, keep richest (msgs, raw); `:dedupe` opt default true, id-less rows pass through
- [x] [P3-T3] `mix faber.scan` report gains TYPE + OPP columns; `--no-dedupe` switch
- [x] [P3-T4] Scan tests — dedup on/off, fingerprint/opportunity fields present, tier2 gate (isolated test/fixtures_dedup/)

## Phase 4 — Final gate
- [x] [P4-T1] Full `mix test` (37 pass); real-data smoke (1,391 deduped / 4,609 raw, ~3.5s); calibration note updated (Findings 3–4); final commit
