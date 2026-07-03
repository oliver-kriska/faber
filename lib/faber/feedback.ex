defmodule Faber.Feedback do
  @moduledoc """
  **The outer loop — post-install feedback.** The inner loop (`Faber.Loop`) optimizes a skill
  against its eval; this closes the loop *around the install*: once a skill is on disk, do later
  sessions actually load it, and how does friction look when they do? Read-only reporting — it
  never retires, edits, or re-proposes a skill; it tells you which one deserves a `faber refine`
  (weak triggering) or removal next.

  For each **Faber-installed** skill (the `.faber.json` provenance marker — the user's own skills
  sharing the dir are never analyzed), scanned sessions are partitioned into those whose
  `skills_used` mention the skill and those that don't. Sessions older than the skill's
  `installed_at` are excluded — a skill can't have fired before it existed (the session's
  transcript mtime is the proxy for "when it ran"). Markers written before `installed_at` existed
  degrade to counting every session.

  Privacy: consumes only `Faber.Scan.Result` aggregates (usage flags + friction scores); no
  transcript text is read or reported.
  """

  alias Faber.{Install, Scan}

  @typedoc """
  Per-skill usage report. `usage_rate` / friction means are `nil` when there is nothing to
  average. `verdict` is a hint, not a decision: `:no_sessions` (nothing ran since install),
  `:unused` (sessions ran, skill never fired — refine its description/triggers or retire it),
  `:low_usage` (fired in <10% of sessions), `:active`.
  """
  @type report :: %{
          skill: String.t(),
          installed_at: DateTime.t() | nil,
          sessions: non_neg_integer(),
          sessions_used: non_neg_integer(),
          usage_rate: float() | nil,
          friction_with: float() | nil,
          friction_without: float() | nil,
          verdict: :no_sessions | :unused | :low_usage | :active
        }

  @scan_keys [:base, :min_messages, :limit, :db, :source, :format, :rank_by]

  @doc """
  Build one `t:report/0` per Faber-installed skill.

  Options: `:dir` (skills root; defaults to the configured dir), `:results` (inject a list of
  `Faber.Scan.Result` — skips the scan; for tests/composition), plus the `Faber.Scan.run/1`
  passthrough keys (`#{inspect(@scan_keys)}`).
  """
  @spec report(keyword()) :: [report()]
  def report(opts \\ []) do
    dir = opts[:dir] || Install.default_dir()
    results = opts[:results] || Scan.run(Keyword.take(opts, @scan_keys))

    dir
    |> Install.list_faber_installed()
    |> Enum.map(&skill_report(&1, results))
  end

  defp skill_report(%{name: name, path: skill_path}, results) do
    installed_at = read_installed_at(skill_path)
    sessions = Enum.filter(results, &session_after?(&1, installed_at))

    {used, unused} =
      Enum.split_with(sessions, fn r ->
        Enum.any?(r.skills_used || [], &(String.downcase(&1) == String.downcase(name)))
      end)

    n = length(sessions)
    n_used = length(used)

    %{
      skill: name,
      installed_at: installed_at,
      sessions: n,
      sessions_used: n_used,
      usage_rate: if(n > 0, do: Float.round(n_used / n, 3)),
      friction_with: mean(used),
      friction_without: mean(unused),
      verdict: verdict(n, n_used)
    }
  end

  defp verdict(0, _used), do: :no_sessions
  defp verdict(_n, 0), do: :unused
  defp verdict(n, used) when used / n < 0.1, do: :low_usage
  defp verdict(_n, _used), do: :active

  defp mean([]), do: nil

  defp mean(results) do
    scores = results |> Enum.map(& &1.friction) |> Enum.filter(&is_number/1)

    case scores do
      [] -> nil
      _ -> Float.round(Enum.sum(scores) / length(scores), 3)
    end
  end

  # The marker is best-effort provenance from Install — parse defensively; any missing/older
  # shape means "unknown install time" and the report counts every session.
  defp read_installed_at(skill_path) do
    marker = skill_path |> Path.dirname() |> Path.join(".faber.json")

    with {:ok, body} <- File.read(marker),
         {:ok, %{"installed_at" => iso}} when is_binary(iso) <- Jason.decode(body),
         {:ok, dt, _offset} <- DateTime.from_iso8601(iso) do
      dt
    else
      _ -> nil
    end
  end

  defp session_after?(_result, nil), do: true

  defp session_after?(%Scan.Result{path: path}, %DateTime{} = installed_at) do
    case File.stat(path, time: :posix) do
      # `>=` — a session written in the install's same second still counts.
      {:ok, %File.Stat{mtime: mtime}} -> mtime >= DateTime.to_unix(installed_at)
      # A vanished/unstatable transcript (or a non-file source): keep it, permissively.
      {:error, _} -> true
    end
  end
end
