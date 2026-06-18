defmodule Faber.LLM do
  @moduledoc """
  The LLM boundary for the skill proposer (M3).

  A thin behaviour over structured-output generation so the engine never hard-depends on a
  particular client or a live API key: tests inject `Faber.LLM.Stub`, while the default impl
  (`Faber.LLM.ReqLLM`) calls `ReqLLM.generate_object/4`. The contract is deliberately small —
  *given a prompt and a schema, return a validated map* — which is exactly what a skill
  proposal needs and what every provider's structured-output mode gives us.

  Configure the implementation and model via application env:

      config :faber, :llm, Faber.LLM.ReqLLM
      config :faber, :llm_model, "anthropic:claude-sonnet-4-6"

  The schema is a keyword list in `ReqLLM`/NimbleOptions form, e.g.
  `[name: [type: :string, required: true], description: [type: :string, required: true]]`.
  """

  @type prompt :: String.t() | [map()]
  @type schema :: keyword()

  @doc "Generate a structured object matching `schema` from `prompt`."
  @callback generate_object(prompt(), schema(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc "The configured implementation module (default `Faber.LLM.ReqLLM`)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:faber, :llm, Faber.LLM.ReqLLM)

  @doc """
  Generate a structured object via the configured (or `:llm`-overridden) implementation.
  """
  @spec generate_object(prompt(), schema(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_object(prompt, schema, opts \\ []) do
    {mod, opts} = Keyword.pop(opts, :llm, impl())
    mod.generate_object(prompt, schema, opts)
  end
end
