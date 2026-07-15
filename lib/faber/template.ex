defmodule Faber.Template do
  @moduledoc """
  A tiny, dependency-free Mustache-subset renderer for adapter scaffolds (`templates/`).

  Supported syntax — enough to fill the plugin-idiom skill scaffold, nothing more:

    * `{{token}}` — replaced by the (stringified) value bound to `token`; unknown → empty.
    * `{{#section}}…{{/section}}` — a repeated/conditional block:
        * value is a **list of maps** → the inner block is rendered once per item, with each
          item's keys merged over the surrounding context (so inner `{{token}}`s resolve
          against the item first, then the parent);
        * value is **falsy** (`nil`, `false`, `""`, `[]`) → the block renders to nothing;
        * value is `true` → the block renders once with the current context.

  Contexts are **string-keyed** by contract (no `String.to_atom/1` on template-controlled
  input). The engine stays domain-free: who builds the context (`Faber.Propose`) decides the
  vocabulary, not this module.
  """

  # Non-greedy, dot-matches-newline; \1 backreference pairs each open/close tag.
  @section ~r/\{\{#([\w.-]+)\}\}(.*?)\{\{\/\1\}\}/s
  @var ~r/\{\{([\w.-]+)\}\}/

  @doc "Render `template` against a string-keyed `context` map."
  @spec render(String.t(), map()) :: String.t()
  def render(template, context) when is_binary(template) and is_map(context) do
    template
    |> render_sections(context)
    |> render_vars(context)
  end

  defp render_sections(template, context) do
    Regex.replace(@section, template, fn _full, key, inner ->
      case Map.get(context, key) do
        list when is_list(list) -> render_each(list, inner, context)
        true -> render(inner, context)
        _falsy -> ""
      end
    end)
  end

  # A list section renders `inner` once per item. A map item is merged over the outer context so
  # `{{field}}` resolves against the item first, falling back to the enclosing scope.
  defp render_each(list, inner, context) do
    Enum.map_join(list, "", fn item ->
      scope = if is_map(item), do: Map.merge(context, item), else: context
      render(inner, scope)
    end)
  end

  defp render_vars(template, context) do
    Regex.replace(@var, template, fn _full, key ->
      case Map.get(context, key) do
        nil -> ""
        v -> to_string(v)
      end
    end)
  end
end
