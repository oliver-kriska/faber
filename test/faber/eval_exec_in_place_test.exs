defmodule Faber.EvalExecInPlaceTest do
  @moduledoc """
  Dispatch tests for `mode: exec-in-place` (ADAPTER_CONTRACT §7.0), against a self-contained fake
  scorer rather than the real plugin — those live in the `:plugin_eval` integration test.

  Tagged `:sidecar` because they spawn `python3`, keeping the default `mix test` hermetic.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Faber.Adapter

  @moduletag :sidecar

  @fixtures Path.expand("../fixtures/exec_in_place", __DIR__)
  @scorer Path.join(@fixtures, "fake_scorer.py")

  @skill_md """
  ---
  name: ecto-changeset-helper
  description: Use when adding a validation to an Ecto changeset, or when a cast/validate pipeline needs a database constraint to back it up.
  ---

  # Ecto Changeset Helper

  ## Iron Laws

  1. Always pair `unique_constraint/3` with a database unique index.

  ## Workflow

  Run the failing test in isolation with `mix test path:line`.

  ```elixir
  user |> cast(attrs, [:email]) |> unique_constraint(:email)
  ```
  """

  # A minimal adapter whose eval references the fake scorer. `root` is the fixtures dir (it must
  # exist — the dispatcher checks), and metadata.source_repo is what `${source_repo}` resolves to.
  defp adapter(mode \\ "ok", opts \\ []) do
    root = Keyword.get(opts, :root, @fixtures)

    %Adapter{
      name: "fake-adapter",
      version: "0.1.0",
      agent_targets: ["claude-code"],
      file_globs: ["mix.exs"],
      metadata: %{"source_repo" => root},
      eval: %{
        "mode" => "exec-in-place",
        "root" => Keyword.get(opts, :root_expr, "${source_repo}"),
        "entrypoints" => %{
          "score" => Keyword.get(opts, :command, "python3 #{@scorer} --mode #{mode}")
        }
      }
    }
  end

  describe "success path" do
    test "scores through the referenced scorer and says which engine did it" do
      {:ok, result} = Faber.Eval.score(@skill_md, adapter: adapter())

      assert result.engine == "adapter:exec-in-place"
      assert result.composite == 0.42
      # The adapter's own dimension — proof this is the referenced scorer's verdict and not the
      # generic native eval wearing its name.
      assert Map.has_key?(result.dimensions, "elixir_idioms")
      refute Map.has_key?(result.dimensions, "conciseness")
    end

    test "maps the scorer's assertion shape onto Faber's" do
      {:ok, result} = Faber.Eval.score(@skill_md, adapter: adapter())
      [assertion | _] = result.dimensions["elixir_idioms"]["assertions"]

      # Upstream says `type`/`desc`; Faber's native shape says `check_type`/`evidence`.
      assert assertion["check_type"] == "uses_with"
      assert assertion["evidence"] == "found `with {:ok, _}`"
      assert result.dimensions["elixir_idioms"]["dimension"] == "elixir_idioms"
    end

    test "the skill arrives as a readable file whose parent directory is the skill name" do
      # Two things the real scorer requires and the plan got wrong: it reads a POSITIONAL PATH (not
      # stdin), and it derives the skill name from basename(dirname(path)) to pick an eval def.
      # The scorer echoes back what it received, since the temp tree is gone by the time we look.
      path = echoed(adapter(), "path-echo")

      assert Path.basename(path) == "SKILL.md"
      assert path |> Path.dirname() |> Path.basename() == "ecto-changeset-helper"
      assert echoed(adapter(), "content-echo") =~ "unique_constraint"
    end

    test "a skill name that isn't a safe path segment is reduced to one segment" do
      # `name:` is LLM-authored frontmatter and becomes a directory, so it must not escape the temp
      # tree. Separators collapse to `-`, leaving a harmless literal.
      md = String.replace(@skill_md, "name: ecto-changeset-helper", "name: ../../etc/pwned")
      dir = adapter() |> echoed(md, "path-echo") |> Path.dirname()

      assert Path.basename(dir) == "..-..-etc-pwned"
      # The real property: one segment below the temp root, not somewhere up the tree.
      assert dir |> Path.dirname() |> Path.basename() =~ ~r/^faber-eval-/
    end

    test "a skill named `..` cannot escape the temp directory" do
      # `..` survives the character filter intact, so it has to be rejected by name.
      md = String.replace(@skill_md, "name: ecto-changeset-helper", "name: ..")
      dir = adapter() |> echoed(md, "path-echo") |> Path.dirname()

      assert Path.basename(dir) == "faber-skill"
      assert dir |> Path.dirname() |> Path.basename() =~ ~r/^faber-eval-/
    end

    test "the temp skill directory is cleaned up" do
      refute adapter() |> echoed("path-echo") |> File.exists?()
    end

    test "the skill is written private — 0600 under a 0700 root" do
      # The body is derived from the user's private transcript and `/tmp` is world-listable on
      # stock macOS/Linux, so defaults (0644/0755) would expose it for the scorer's whole run.
      # Asserted from *inside* the scorer (fake_scorer.py stats its own argument): the dispatcher
      # deletes the tree the instant the scorer exits, so mid-run is both the only moment these
      # perms are observable and the only moment they matter.
      assert echoed(adapter(), "perms-echo") == "file=0o600 root=0o700"
    end

    defp echoed(adapter, md \\ @skill_md, id) do
      {:ok, result} = Faber.Eval.score(md, adapter: adapter)

      result.dimensions["elixir_idioms"]["assertions"]
      |> Enum.find(&(&1["id"] == id))
      |> Map.fetch!("evidence")
    end

    test "composite is threshold-gated like any other engine" do
      {:fail, result} = Faber.Eval.gate(@skill_md, adapter: adapter(), threshold: 0.9)
      assert result.composite == 0.42

      {:pass, _} = Faber.Eval.gate(@skill_md, adapter: adapter(), threshold: 0.4)
    end
  end

  describe "every failure falls back to native — loudly, and never claims to be the adapter" do
    test "non-zero exit" do
      log = capture_log(fn -> assert {:ok, _} = fallback(adapter("boom")) end)
      assert log =~ "exec_in_place_exit"
      assert log =~ "NOT the adapter's stack-specific verdict"
    end

    test "undecodable output" do
      log = capture_log(fn -> assert {:ok, _} = fallback(adapter("garbage")) end)
      assert log =~ "exec_in_place_bad_output"
    end

    test "valid JSON that isn't a score payload" do
      log = capture_log(fn -> assert {:ok, _} = fallback(adapter("badshape")) end)
      assert log =~ "exec_in_place_bad_shape"
    end

    test "missing source repo" do
      log =
        capture_log(fn ->
          assert {:ok, _} = fallback(adapter("ok", root: "/nonexistent/repo/xyz"))
        end)

      assert log =~ "exec_in_place_root_missing"
    end

    test "unresolvable ${source_repo}" do
      broken = %{adapter() | metadata: %{}}
      log = capture_log(fn -> assert {:ok, _} = fallback(broken) end)
      assert log =~ "exec_in_place_root_unresolved"
    end

    test "missing interpreter" do
      log =
        capture_log(fn ->
          assert {:ok, _} = fallback(adapter("ok", command: "definitely-not-a-real-binary-xyz"))
        end)

      assert log =~ "exec_in_place"
    end

    defp fallback(adapter) do
      result = Faber.Eval.score(@skill_md, adapter: adapter)
      {:ok, r} = result

      # The fallback is the generic native eval, and it says so — a PASS here certifies markdown
      # structure, not the stack's bar (finding F3: the old code claimed an attempt it never made).
      assert r.engine == "native:fallback"
      assert Map.has_key?(r.dimensions, "conciseness")
      refute Map.has_key?(r.dimensions, "elixir_idioms")
      result
    end
  end

  describe "trigger composition [codex #6 — exec-in-place trigger dispatch is deferred]" do
    # The adapter's eval.yaml declares `entrypoints.trigger`, but dispatching it is deliberately
    # deferred: trigger stays on Faber.Eval.Trigger. These guard that composition (no LLM call —
    # a proposal with no fixtures skips).
    defp proposal do
      %Faber.Proposal{
        name: "ecto-changeset-helper",
        description: "Use when adding a validation to an Ecto changeset in a Phoenix context.",
        rationale: "Changesets are where validation friction concentrates.",
        iron_laws: ["Always pair unique_constraint/3 with a database unique index."],
        example: "user\n|> cast(attrs, [:email])\n|> unique_constraint(:email)",
        workflow: ["Run the failing test with `mix test path:line`"]
      }
    end

    test "--trigger routes through Faber's Trigger, not the adapter's trigger entrypoint" do
      {:ok, result} = Faber.Eval.score(proposal(), adapter: adapter(), trigger: true)

      # Faber's Trigger ran and skipped (no fixtures) — the adapter's `entrypoints.trigger` was
      # never dispatched. Structural scoring still came from the referenced scorer.
      assert result.trigger == {:skipped, :no_fixtures}
      assert result.engine == "adapter:exec-in-place"
    end

    test "without --trigger nothing behavioral is folded" do
      {:ok, result} = Faber.Eval.score(proposal(), adapter: adapter(), trigger: false)

      refute Map.has_key?(result, :trigger)
      assert result.engine == "adapter:exec-in-place"
    end
  end

  describe "command execution is not a shell" do
    test "an entrypoint cannot smuggle shell metacharacters" do
      # Pack-supplied commands run without a shell, so `;` is just another argv token — it must not
      # chain a second command. The run fails (no such binary) and falls back; nothing is executed.
      marker =
        Path.join(System.tmp_dir!(), "faber-shell-escape-#{System.unique_integer([:positive])}")

      cmd = "python3 #{@scorer} --mode ok ; touch #{marker}"

      capture_log(fn ->
        assert {:ok, _} = Faber.Eval.score(@skill_md, adapter: adapter("ok", command: cmd))
      end)

      refute File.exists?(marker)
    end
  end
end
