defmodule Faber.LLM.ClaudeCLI do
  @moduledoc """
  Keyless `Faber.LLM` backend that shells out to the local Claude Code CLI (`claude -p`).

  Uses your existing Claude Code auth — **no API key, no `req_llm` network path** — which is the
  easiest way to run the proposer/loop on your own machine. Structured output is coaxed out of the
  text CLI: the schema is rendered into a "return ONLY JSON with these fields" instruction appended
  to the system prompt, the response is requested as `--output-format json`, and the model's text
  (the envelope's `result`) is parsed back into a map.

  Config:

      config :faber, :llm, Faber.LLM.ClaudeCLI
      config :faber, :claude_bin, "claude"          # path/name of the CLI
      config :faber, :claude_model, "sonnet"        # optional; omit to use the CLI default
      config :faber, :claude_timeout_ms, 300_000    # kill a hung CLI call (default 5 min)

  The parsing helpers (`render_schema/1`, `extract_json/1`, `parse_envelope/1`) are pure and unit
  tested; only `generate_object/3` does I/O.
  """

  @behaviour Faber.LLM

  @impl Faber.LLM
  def generate_object(prompt, schema, opts) do
    bin = opts[:claude_bin] || Application.get_env(:faber, :claude_bin, "claude")
    system = build_system(opts[:system_prompt], schema)
    model = opts[:model] || Application.get_env(:faber, :claude_model)

    timeout =
      opts[:timeout] || Application.get_env(:faber, :claude_timeout_ms, :timer.minutes(5))

    case System.find_executable(bin) do
      nil -> {:error, {:claude_cli_unavailable, bin}}
      resolved -> run(resolved, to_string(prompt), system, model, timeout)
    end
  end

  # Redirect stdin from /dev/null so `claude -p` doesn't wait 3s for piped input that never comes
  # (the prompt is on the command line). `System.cmd/3` can't close the child's stdin, so wrap in
  # `sh -c`; every dynamic value goes through the ENVIRONMENT, never the command string, so prompt /
  # system content can't be word-split or shell-injected. `${VAR:+--flag "$VAR"}` omits empty flags.
  defp run(bin, prompt, system, model, timeout) do
    script =
      ~s(exec "$FB_BIN" -p "$FB_PROMPT" --output-format json) <>
        ~s( ${FB_SYS:+--append-system-prompt "$FB_SYS"}) <>
        ~s( ${FB_MODEL:+--model "$FB_MODEL"} < /dev/null)

    env = [
      {"FB_BIN", bin},
      {"FB_PROMPT", prompt},
      {"FB_SYS", system},
      {"FB_MODEL", to_string(model || "")}
    ]

    case Faber.Subprocess.run("sh", ["-c", script],
           env: env,
           stderr_to_stdout: false,
           timeout: timeout
         ) do
      {:error, :timeout} ->
        {:error, {:claude_cli_timeout, timeout}}

      {out, 0} ->
        with {:ok, text} <- parse_envelope(out),
             {:ok, object} <- extract_json(text) do
          {:ok, object}
        else
          _ -> {:error, {:claude_cli_parse, out}}
        end

      {out, code} ->
        {:error, {:claude_cli_exit, code, out}}
    end
  rescue
    e in ErlangError -> {:error, {:claude_cli_unavailable, e}}
  end

  @doc "Append the JSON-shape instruction (from `schema`) to the caller's system prompt."
  @spec build_system(String.t() | nil, keyword()) :: String.t()
  def build_system(system, schema) do
    [system, render_schema(schema)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  @doc "Render a ReqLLM/NimbleOptions schema into a human-readable JSON-shape instruction."
  @spec render_schema(keyword()) :: String.t()
  def render_schema(schema) do
    fields =
      Enum.map_join(schema, "\n", fn {key, spec} ->
        "- #{key}: #{type_label(spec[:type])}#{if spec[:required], do: " (required)", else: ""}"
      end)

    """
    Return ONLY a single JSON object — no prose, no markdown, no code fence — with these fields:
    #{fields}
    """
  end

  @doc "Parse the `claude --output-format json` envelope and return the assistant text."
  @spec parse_envelope(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_envelope(out) do
    case Jason.decode(out) do
      {:ok, %{"result" => text}} when is_binary(text) -> {:ok, text}
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      # Not the expected envelope — fall back to treating the raw output as the text.
      {:ok, _} -> {:ok, out}
      {:error, _} -> {:ok, out}
    end
  end

  @doc "Extract a JSON object from model text (tolerates code fences and surrounding prose)."
  @spec extract_json(String.t()) :: {:ok, map()} | {:error, term()}
  def extract_json(text) do
    cleaned = strip_fences(text)

    case Jason.decode(cleaned) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> slice_object(cleaned)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp type_label(:string), do: "string"
  defp type_label(:integer), do: "integer"
  defp type_label(:float), do: "number"
  defp type_label(:boolean), do: "boolean"
  defp type_label({:list, inner}), do: "array of #{type_label(inner)}s"
  defp type_label(_), do: "value"

  defp strip_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/m, "")
    |> String.replace(~r/```\s*$/m, "")
    |> String.trim()
  end

  defp slice_object(text) do
    with {s, _} <- :binary.match(text, "{"),
         [_ | _] = closes <- :binary.matches(text, "}"),
         {e, _} <- List.last(closes),
         candidate <- binary_part(text, s, e - s + 1),
         {:ok, map} when is_map(map) <- Jason.decode(candidate) do
      {:ok, map}
    else
      _ -> {:error, :no_json_object}
    end
  end
end
