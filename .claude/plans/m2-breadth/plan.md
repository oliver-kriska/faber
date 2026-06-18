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
- [ ] [P2-T1] Implement `Faber.Detect.opportunity/1` (retry→investigate, 50+ tools no plan, 3+ test/compile→verify, 2+ gh pr→pr-review, 10+ edits→review; score = min(n×0.2, 1.0)); used-skill detection from Skill calls + attributionSkill + /xxx:cmd text
- [ ] [P2-T2] Tests for opportunity + used-skill exclusion

## Phase 3 — Scan integration + sidechain dedup
- [ ] [P3-T1] Extend `Faber.Scan.Result` with fingerprint + opportunity; complete tier-2 criteria (friction>0.35 OR opportunity>0.5 OR skills-used OR msgs>50)
- [ ] [P3-T2] Sidechain dedup in `Faber.Scan.run/1` (collapse same session_id, keep richest; `:dedupe` opt default true)
- [ ] [P3-T3] Update `mix faber.scan` report (fingerprint + opportunity columns)
- [ ] [P3-T4] Scan tests (dedup, fingerprint/opportunity present, tier2)

## Phase 4 — Final gate
- [ ] [P4-T1] Full `mix test`; real-data smoke run; update calibration research note; final commit
