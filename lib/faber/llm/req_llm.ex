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
    model = opts[:model] || Application.get_env(:faber, :llm_model, @default_model)
    req_opts = Keyword.take(opts, @passthrough_opts)

    case ReqLLM.generate_object(model, prompt, schema, req_opts) do
      {:ok, response} -> {:ok, ReqLLM.Response.object(response)}
      {:error, _} = err -> err
    end
  end
end
