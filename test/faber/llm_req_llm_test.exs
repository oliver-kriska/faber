defmodule Faber.LLM.ReqLLMTest do
  # `async: false` — these mutate the global `:llm_model` application env.
  use ExUnit.Case, async: false

  alias Faber.LLM.ReqLLM

  @schema [name: [type: :string, required: true]]

  setup do
    # Snapshot and restore the env each test touches, so order/other tests aren't affected.
    prev = Application.get_env(:faber, :llm_model)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:faber, :llm_model, prev),
        else: Application.delete_env(:faber, :llm_model)
    end)

    :ok
  end

  describe "build_call/1 — model + opts resolution (no network)" do
    test "falls back to the default model when neither opts nor config sets one" do
      Application.delete_env(:faber, :llm_model)
      assert {model, _} = ReqLLM.build_call([])
      assert model == ReqLLM.default_model()
    end

    test "config :llm_model overrides the default" do
      Application.put_env(:faber, :llm_model, "openai:gpt-x")
      assert {"openai:gpt-x", _} = ReqLLM.build_call([])
    end

    test "opts[:model] wins over both config and the default" do
      Application.put_env(:faber, :llm_model, "openai:gpt-x")

      assert {"anthropic:claude-opus-4-8", _} =
               ReqLLM.build_call(model: "anthropic:claude-opus-4-8")
    end

    test "forwards only whitelisted Req opts, dropping engine plumbing" do
      {_model, req_opts} =
        ReqLLM.build_call(
          temperature: 0.2,
          max_tokens: 500,
          system_prompt: "sys",
          # plumbing that must never reach the provider:
          model: "m",
          llm: SomeBackend,
          sidecar: SomeSidecar,
          adapter: :elixir,
          feedback: "revise"
        )

      assert req_opts[:temperature] == 0.2
      assert req_opts[:max_tokens] == 500
      assert req_opts[:system_prompt] == "sys"

      for leaked <- [:model, :llm, :sidecar, :adapter, :feedback] do
        refute Keyword.has_key?(req_opts, leaked), "#{leaked} leaked into the provider request"
      end
    end
  end

  describe "generate_object/3 — error passthrough (no network)" do
    test "surfaces a provider-resolution error as {:error, _} instead of crashing" do
      # An unknown provider fails synchronously in ReqLLM before any HTTP — proves the wrapper
      # passes provider errors through rather than raising.
      assert {:error, _} = ReqLLM.generate_object("hi", @schema, model: "bogusprovider:nope")
    end
  end
end
