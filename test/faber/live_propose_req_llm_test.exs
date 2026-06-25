defmodule Faber.LiveProposeReqLLMTest do
  # The API-key counterpart to live_propose_test.exs (which is keyless via `claude -p`). This drives
  # the SAME pipeline through the default ReqLLM backend against the real Anthropic API, proving the
  # one edge a key-less run can't: ReqLLM.generate_object success → ReqLLM.Response.object mapping.
  #
  # Tagged `:live_api` and excluded from `mix test`, `mix test.full`, AND `mix test.live` — it costs
  # money and needs a key. Run it with the env loaded:
  #
  #     set -a; . ./.env; set +a            # exports CLAUDE_API
  #     mix test.live.api                   # alias for `--include live_api`
  #
  # The test maps CLAUDE_API → ANTHROPIC_API_KEY (what ReqLLM reads) itself, and skips (no failure)
  # when no key is present, so a key-less `mix test.live.api` is a clean no-op.
  use ExUnit.Case, async: false

  @moduletag :live_api
  @moduletag timeout: 180_000

  alias Faber.{Adapter, Eval, Install, Propose, Scan}

  @fixtures [base: "test/fixtures", min_messages: 0]
  @model "anthropic:claude-sonnet-4-6"

  describe "live propose via the ReqLLM backend (real Anthropic API)" do
    test "scan → propose(ReqLLM) → native eval → install yields a well-formed skill" do
      case api_key() do
        nil ->
          IO.puts("\n[skipped] ReqLLM live test: set CLAUDE_API or ANTHROPIC_API_KEY to run it")

        key ->
          with_anthropic_key(key, fn ->
            {:ok, adapter} = Adapter.load("adapters/faber-elixir")
            assert [%Scan.Result{} = result | _] = Scan.run(@fixtures ++ [rank_by: :raw])

            # max_tokens generous enough that the structured skill JSON isn't truncated; one call.
            assert {:ok, proposal} =
                     Propose.propose(result, adapter,
                       llm: Faber.LLM.ReqLLM,
                       model: @model,
                       max_tokens: 2000
                     )

            # Structure, not content (nondeterministic). Name must be a safe path segment.
            assert is_binary(proposal.name) and proposal.name =~ ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
            assert is_binary(proposal.description) and String.length(proposal.description) >= 50
            assert is_list(proposal.iron_laws) and proposal.iron_laws != []

            skill = Propose.render_skill_md(proposal, adapter)
            assert {:ok, score} = Eval.score(skill, engine: :native)
            assert is_float(score.composite)
            assert score.composite >= 0.6, "live composite #{score.composite} below floor"

            tmp =
              Path.join(System.tmp_dir!(), "faber-live-api-#{System.unique_integer([:positive])}")

            on_exit(fn -> File.rm_rf(tmp) end)

            assert {:ok, path} =
                     Install.install(proposal, dir: tmp, adapter: adapter, force: true)

            assert File.exists?(path)
          end)
      end
    end
  end

  # Accept either the standard var or the user's CLAUDE_API.
  defp api_key do
    case System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API") do
      k when is_binary(k) and k != "" -> k
      _ -> nil
    end
  end

  # Make `key` visible to ReqLLM (which reads ANTHROPIC_API_KEY) for the duration, then restore.
  defp with_anthropic_key(key, fun) do
    prev = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", key)

    try do
      fun.()
    after
      if prev,
        do: System.put_env("ANTHROPIC_API_KEY", prev),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end
  end
end
