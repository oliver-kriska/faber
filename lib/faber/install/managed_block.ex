defmodule Faber.Install.ManagedBlock do
  @moduledoc """
  A digest-guarded, idempotent "managed block" for injecting Faber-owned content into a *shared*
  file (an agent's `CLAUDE.md` / `AGENTS.md` / rules file) without clobbering the user's own text.

  The block is self-delimiting:

      <!-- FABER:BEGIN sha256:<digest> -->
      <body>
      <!-- FABER:END -->

  `upsert/2` replaces an existing block in place (or appends one), so re-running is byte-stable.
  The digest is computed over the body at write time, so `tampered?/1` can tell a hand-edited block
  from an untouched one — the install layer refuses to overwrite a hand-edited block unless forced.
  All functions are pure (no I/O), so the whole mechanism is unit-testable.
  """

  @begin_re ~r/<!-- FABER:BEGIN sha256:([0-9a-f]+) -->/
  @block_re ~r/<!-- FABER:BEGIN sha256:[0-9a-f]+ -->\n.*?\n<!-- FABER:END -->/s
  @capture_re ~r/<!-- FABER:BEGIN sha256:([0-9a-f]+) -->\n(.*?)\n<!-- FABER:END -->/s

  @digest_len 12

  @doc "Short content digest (first #{@digest_len} hex chars of sha256) over the trimmed body."
  @spec digest(String.t()) :: String.t()
  def digest(body) do
    :sha256
    |> :crypto.hash(String.trim(body))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @digest_len)
  end

  @doc "Render `body` as a full managed block (markers + digest). The body is trimmed."
  @spec render(String.t()) :: String.t()
  def render(body) do
    b = String.trim(body)
    "<!-- FABER:BEGIN sha256:#{digest(b)} -->\n#{b}\n<!-- FABER:END -->"
  end

  @doc "True if `content` already contains a Faber managed block."
  @spec has_block?(String.t()) :: boolean()
  def has_block?(content), do: Regex.match?(@begin_re, content)

  @doc """
  Extract the managed block from `content`. Returns `{:ok, %{body, digest}}` (the recorded digest
  as written in the marker) or `:none`.
  """
  @spec extract(String.t()) :: {:ok, %{body: String.t(), digest: String.t()}} | :none
  def extract(content) do
    case Regex.run(@capture_re, content) do
      [_full, digest, body] -> {:ok, %{body: body, digest: digest}}
      _ -> :none
    end
  end

  @doc """
  Insert or replace the managed block carrying `body`. An existing block is replaced **in place**
  (preserving surrounding text); otherwise the block is appended after a blank line. Idempotent:
  upserting the same body yields identical bytes.
  """
  @spec upsert(String.t(), String.t()) :: String.t()
  def upsert(content, body) do
    block = render(body)

    if has_block?(content) do
      # Function replacement (not a pattern string) so body content with `\0`/`\1` isn't treated
      # as a backreference.
      Regex.replace(@block_re, content, fn _ -> block end)
    else
      append(content, block)
    end
  end

  @doc """
  True if `content`'s block already carries `body`. Compares the **actual** block body to `body`
  (not the recorded marker digest), so a hand-edited block reads as out-of-sync, not in-sync.
  """
  @spec in_sync?(String.t(), String.t()) :: boolean()
  def in_sync?(content, body) do
    case extract(content) do
      {:ok, %{body: current}} -> digest(current) == digest(body)
      :none -> false
    end
  end

  @doc """
  True if the block's body was hand-edited after Faber wrote it — i.e. the body no longer matches
  the digest recorded in its own marker. `false` when there's no block.
  """
  @spec tampered?(String.t()) :: boolean()
  def tampered?(content) do
    case extract(content) do
      {:ok, %{body: body, digest: recorded}} -> digest(body) != recorded
      :none -> false
    end
  end

  defp append("", block), do: block <> "\n"
  defp append(content, block), do: String.trim_trailing(content) <> "\n\n" <> block <> "\n"
end
