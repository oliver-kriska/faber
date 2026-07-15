defmodule Faber.EvalPluginIntegrationTest do
  @moduledoc """
  The real exec-in-place run: the `faber-elixir` adapter scoring a skill through the actual plugin
  repo's `lab.eval.scorer`, with zero diffs to that repo (the extraction premise).

  Environment-bound — it needs both `python3` and the referenced repo present — so it is tagged
  `:plugin_eval` and excluded by default. `mix test.full` includes it.

      mix test --include plugin_eval test/faber/eval_plugin_integration_test.exs

  `test/faber/eval_exec_in_place_test.exs` covers the dispatch logic against a fake scorer; that
  proves *our* behavior but would keep passing if the real scorer's JSON shape drifted underneath
  us. This is the test that catches that drift.
  """
  use ExUnit.Case, async: true

  alias Faber.Adapter

  @moduletag :plugin_eval

  # A structurally sound Elixir/Phoenix skill — good enough that a real, unmocked 8-dimension
  # scorer should rate it well. The point is that the adapter's bar ran, not the exact number.
  @skill_md """
  ---
  name: ecto-changeset-helper
  description: Use when adding validations to an Ecto changeset in a Phoenix context, or when a cast/validate pipeline needs a database constraint to back it up. Covers unique_constraint, foreign_key_constraint, and validate_required.
  ---

  # Ecto Changeset Helper

  ## Iron Laws

  1. Always pair a `unique_constraint/3` with a database unique index — the constraint only
     converts a database error into a changeset error, it does not create the guarantee.
  2. Never rely on `validate_required/3` alone for uniqueness; it cannot see other rows.

  ## Workflow

  1. Run the failing test in isolation with `mix test path:line`.
  2. Add the constraint to the changeset, then the matching index in a migration.

  ```elixir
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> unique_constraint(:email)
  end
  ```
  """

  setup_all do
    {:ok, adapter} = Adapter.load(Faber.adapter_dir())
    root = Adapter.eval_root(adapter)

    if is_nil(root) or not File.dir?(root) do
      raise """
      The faber-elixir adapter references a source repo that isn't on this machine:

          #{inspect(root)}

      This test is opt-in (`--include plugin_eval`) and needs the plugin repo present. Nothing is
      wrong with the code; there is just nothing here to integrate against.
      """
    end

    {:ok, adapter: adapter, root: root}
  end

  test "scores through the plugin's real lab.eval.scorer", %{adapter: adapter} do
    {:ok, result} = Faber.Eval.score(@skill_md, adapter: adapter)

    # The honesty guarantee (finding F3): this claims to be the adapter's verdict only when it is.
    assert result.engine == "adapter:exec-in-place"

    # The plugin's 8 dimensions — NOT Faber's generic 6. This is the assertion that would have
    # failed before the dispatch existed, when exec-in-place silently returned a native result.
    for dimension <-
          ~w(completeness accuracy conciseness triggering safety clarity specificity behavioral) do
      assert Map.has_key?(result.dimensions, dimension),
             "expected the plugin's `#{dimension}` dimension, got: " <>
               inspect(Map.keys(result.dimensions))
    end

    assert is_float(result.composite)
    assert result.composite > 0.0 and result.composite <= 1.0
  end

  test "the decoded shape matches what Faber's result contract expects", %{adapter: adapter} do
    # Risk 4: the plugin's output could drift. Pin the fields Faber actually reads.
    {:ok, result} = Faber.Eval.score(@skill_md, adapter: adapter)
    dimension = result.dimensions["completeness"]

    assert is_float(dimension["score"])
    assert is_integer(dimension["passed"])
    assert is_integer(dimension["total"])
    assert dimension["dimension"] == "completeness"

    assertion = hd(dimension["assertions"])
    # Upstream emits `type`/`desc`; the dispatcher maps them onto Faber's native shape.
    assert is_binary(assertion["check_type"])
    assert is_binary(assertion["evidence"])
    assert is_boolean(assertion["passed"])

    # `composite` arrives pre-normalized with no weight_total, so 1.0 keeps fold_behavioral exact.
    assert result.weight_total == 1.0
  end

  test "a structurally sound skill clears the default gate", %{adapter: adapter} do
    assert {:pass, result} = Faber.Eval.gate(@skill_md, adapter: adapter)
    assert result.engine == "adapter:exec-in-place"
  end

  test "the plugin repo is never written to (extraction premise)", %{root: root} do
    # The scorer runs with cwd = the plugin repo, so a careless dispatch could drop temp files in
    # it. The skill must be written to our own temp tree instead.
    before = git_status(root)
    {:ok, _} = Faber.Eval.score(@skill_md, adapter: Adapter.load(Faber.adapter_dir()) |> elem(1))

    assert git_status(root) == before, "the eval run dirtied the referenced plugin repo"
  end

  defp git_status(root) do
    {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: root)
    out
  end
end
