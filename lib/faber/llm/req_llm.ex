defmodule Faber.LLM.ReqLLM do
  @moduledoc """
  Default `Faber.LLM` implementation: a thin passthrough to `ReqLLM.generate_object/4`.

  The model comes from `opts[:model]`, else `config :faber, :llm_model`, else a sane Anthropic
  default. A live call needs the provider's API key in the environment (e.g.
  `ANTHROPIC_API_KEY`); without it `ReqLLM` returns `{:error, ...}` and the proposer surfaces
  the failure rather than crashing.
  """

  @behaviour Faber.LLM

  @default_model "anthropic:claude-sonnet-4-6"

  @passthrough_opts [
    :temperature,
    :max_tokens,
    :top_p,
    :system_prompt,
    :provider_options
  ]

  @impl Faber.LLM
  def generate_object(prompt, schema, opts) do
    {model, req_opts} = build_call(opts)

    case ReqLLM.generate_object(model, prompt, schema, req_opts) do
      {:ok, response} -> {:ok, ReqLLM.Response.object(response)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Resolve the model spec and the Req-bound options from `opts` — the pure decision layer, exposed
  so it's unit-testable without a network call (only `generate_object/3` does I/O).

  Model precedence: `opts[:model]` → `config :faber, :llm_model` → `#{@default_model}`. Only the
  whitelisted `#{inspect(@passthrough_opts)}` keys are forwarded to the provider; engine plumbing
  (`:llm`, `:sidecar`, `:adapter`, `:feedback`, …) is dropped so it never leaks into the request.
  """
  @spec build_call(keyword()) :: {String.t(), keyword()}
  def build_call(opts) do
    model = opts[:model] || Application.get_env(:faber, :llm_model, @default_model)
    {model, Keyword.take(opts, @passthrough_opts)}
  end

  @doc "The fallback model spec used when neither `opts[:model]` nor `config :faber, :llm_model` is set."
  @spec default_model() :: String.t()
  def default_model, do: @default_model
end
