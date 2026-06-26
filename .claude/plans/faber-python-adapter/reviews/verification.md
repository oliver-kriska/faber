# Verification Report — Faber Python Adapter

## Project Config

- **Elixir** 1.20+ / OTP 27+
- **Test aliases**: `test.full` (sidecar + ccrider), `test.live` (keyless), `test.live.api` (API)
- **Build**: `mix compile`, `mix format`, no Credo/Dialyzer/Sobelow configured
- **Dependencies**: Jason, YAML, ReqLLM, Phoenix 1.7, Bandit, Anubis MCP, Burrito, LazyHTML (test)

## Summary

| Step | Status | Details |
|------|--------|---------|
| Format | ✅ | `mix format --check-formatted` OK |
| Compile | ✅ | `mix compile --warnings-as-errors` OK |
| Credo | ⏭ | Not installed |
| Test (unit) | ✅ | 275 passed, 7 excluded |
| Test (full) | ✅ | 280 passed, 2 excluded |
| Dialyzer | ⏭ | Not installed |
| Sobelow | ⏭ | Not installed |

## Overall: ✅ PASS

All core verification steps passed. The hermetic unit test suite (`mix test`) excludes `:sidecar`, `:ccrider`, `:live`, `:live_api` tags as configured. Full test suite (`mix test.full`) includes sidecar parity tests (native↔Python eval drift detection) and completed successfully. The pre-existing scheduler test error log ("faber schedule: run #1 crashed — :killed") is intentional and not a failure — confirmed by the final `Result: N passed` lines.

### Test Counts

- **`mix test`**: 275 passed, 7 excluded
- **`mix test.full`**: 280 passed, 2 excluded (sidecar/ccrider now included)

## Additional Tests Available

- `mix test.live` — keyless live propose (real `claude -p` model, no API key, real cost)
- `mix test.live.api` — API-backed propose (ReqLLM, needs `CLAUDE_API` in `.env`, real cost)
