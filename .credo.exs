# Credo config for Faber — the linter half of the `mix verify` gate (Iron Law #22).
#
# Philosophy: this file only ever relaxes a check when Faber's code style is a *deliberate*
# choice that the default disagrees with, and each relaxation says why. Genuine findings get
# fixed in the code instead — a gate nobody can turn green stops being read.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/burrito_out/"]
      },
      strict: true,
      color: true,
      checks: [
        # Faber deliberately calls a handful of modules fully-qualified rather than aliasing
        # them: at the call site `Faber.Ingest.Format.cast(f)` and `Faber.Eval.Trigger.score(p)`
        # name the pipeline stage they belong to, while a bare `Format.cast/1` / `Trigger.score/1`
        # would be ambiguous in a codebase whose contexts are exactly Ingest/Detect/Eval/Loop.
        # Still flag a module that's fully-qualified over and over — that one wants an alias.
        # (`if_nested_deeper_than: 2` is Credo's own default — restated because naming a check
        # here resets every param it doesn't mention back to the check's stricter built-in
        # defaults, which would flag ~3x more.)
        {Credo.Check.Design.AliasUsage, [if_nested_deeper_than: 2, if_called_more_often_than: 2]},

        # Default max_nesting is 2. Faber's parsers walk untrusted, deeply-optional input
        # (session JSONL, adapter YAML, SQLite rows) where a `case` inside a `for` inside a
        # `with` is the honest shape; flattening it into helpers named `do_parse_2/1` would
        # hurt more than it helps. 3 keeps the genuinely gnarly ones visible.
        {Credo.Check.Refactor.Nesting, [max_nesting: 3]},

        # Keep Credo's default complexity ceiling (9) — no project-specific reason to move it.
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 9]}
      ]
    }
  ]
}
