defmodule Faber.FeedbackTest do
  use ExUnit.Case, async: true

  alias Faber.{Feedback, Install, Scan}

  # A minimal scanned session: only the fields Feedback consumes (usage flags + friction +
  # transcript path for the mtime cutoff).
  defp result(path, friction, skills_used) do
    %Scan.Result{
      path: path,
      session_id: Path.basename(path, ".jsonl"),
      friction: friction,
      raw: friction * 10,
      dominant_signal: :retry_loops,
      signals: %{},
      fingerprint: "bug-fix",
      fingerprint_confidence: 0.5,
      opportunity: 0.2,
      missed: [],
      skills_used: skills_used,
      tool_count: 5,
      error_count: 1,
      message_count: 20,
      parse_errors: 0,
      tier2: true
    }
  end

  # A transcript file on disk (mtime = now, i.e. after any marker written earlier in the test).
  defp transcript!(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, "{}\n")
    path
  end

  defp rewrite_installed_at!(skill_md_path, iso) do
    marker = skill_md_path |> Path.dirname() |> Path.join(".faber.json")
    data = marker |> File.read!() |> Jason.decode!()
    File.write!(marker, Jason.encode!(Map.put(data, "installed_at", iso)) <> "\n")
  end

  describe "report/1" do
    @tag :tmp_dir
    test "partitions sessions by usage and compares friction", %{tmp_dir: dir} do
      skills = Path.join(dir, "skills")
      {:ok, path_a} = Install.install({"skill-a", "---\nname: skill-a\n---\n# A\n"}, dir: skills)
      {:ok, path_b} = Install.install({"skill-b", "---\nname: skill-b\n---\n# B\n"}, dir: skills)
      # Sessions must post-date the install — pin both markers safely into the past.
      rewrite_installed_at!(path_a, "2000-01-01T00:00:00Z")
      rewrite_installed_at!(path_b, "2000-01-01T00:00:00Z")

      results = [
        result(transcript!(dir, "s1.jsonl"), 0.2, ["skill-a"]),
        result(transcript!(dir, "s2.jsonl"), 0.8, []),
        result(transcript!(dir, "s3.jsonl"), 0.6, ["other-skill"])
      ]

      assert [a, b] = Feedback.report(dir: skills, results: results)

      assert %{skill: "skill-a", sessions: 3, sessions_used: 1, verdict: :active} = a
      assert a.usage_rate == 0.333
      assert a.friction_with == 0.2
      assert a.friction_without == 0.7
      assert %DateTime{} = a.installed_at

      # skill-b never fired although sessions ran — the retire/refine hint.
      assert %{skill: "skill-b", sessions: 3, sessions_used: 0, verdict: :unused} = b
      assert b.friction_with == nil
    end

    @tag :tmp_dir
    test ":low_usage when the skill fired in under 10% of sessions", %{tmp_dir: dir} do
      skills = Path.join(dir, "skills")
      {:ok, path} = Install.install({"rare", "---\nname: rare\n---\n# R\n"}, dir: skills)
      rewrite_installed_at!(path, "2000-01-01T00:00:00Z")

      results =
        for i <- 1..11 do
          used = if i == 1, do: ["rare"], else: []
          result(transcript!(dir, "s#{i}.jsonl"), 0.5, used)
        end

      assert [%{skill: "rare", sessions: 11, sessions_used: 1, verdict: :low_usage}] =
               Feedback.report(dir: skills, results: results)
    end

    # session_after?/2's documented permissive fallback: a transcript that can't be stat'ed (a
    # vanished file, or a non-file source handle like OpenCode's "db#session") is KEPT. A strict
    # implementation would report :no_sessions here.
    @tag :tmp_dir
    test "a vanished transcript is counted permissively, not dropped", %{tmp_dir: dir} do
      skills = Path.join(dir, "skills")
      {:ok, path} = Install.install({"ghost", "---\nname: ghost\n---\n# G\n"}, dir: skills)
      rewrite_installed_at!(path, "2000-01-01T00:00:00Z")

      results = [result(Path.join(dir, "vanished.jsonl"), 0.5, [])]

      assert [%{skill: "ghost", sessions: 1, verdict: :unused}] =
               Feedback.report(dir: skills, results: results)
    end

    @tag :tmp_dir
    test "sessions older than installed_at are excluded (→ :no_sessions)", %{tmp_dir: dir} do
      skills = Path.join(dir, "skills")
      {:ok, path} = Install.install({"future", "---\nname: future\n---\n# F\n"}, dir: skills)
      # The marker post-dates every transcript mtime → nothing can have used it yet.
      rewrite_installed_at!(path, "2099-01-01T00:00:00Z")

      results = [result(transcript!(dir, "s1.jsonl"), 0.5, ["future"])]

      assert [%{sessions: 0, sessions_used: 0, verdict: :no_sessions, usage_rate: nil}] =
               Feedback.report(dir: skills, results: results)
    end

    @tag :tmp_dir
    test "a marker without installed_at degrades to counting every session", %{tmp_dir: dir} do
      skills = Path.join(dir, "skills")
      {:ok, path} = Install.install({"legacy", "---\nname: legacy\n---\n# L\n"}, dir: skills)

      # Pre-installed_at marker shape (written by an older Faber).
      marker = path |> Path.dirname() |> Path.join(".faber.json")
      File.write!(marker, ~s({"installed_by":"faber","name":"legacy"}\n))

      results = [result(transcript!(dir, "s1.jsonl"), 0.4, ["legacy"])]

      assert [%{installed_at: nil, sessions: 1, sessions_used: 1, verdict: :active}] =
               Feedback.report(dir: skills, results: results)
    end

    @tag :tmp_dir
    test "usage matching is case-insensitive and ignores the user's own skills", %{tmp_dir: dir} do
      skills = Path.join(dir, "skills")
      {:ok, path} = Install.install({"cased", "---\nname: cased\n---\n# C\n"}, dir: skills)
      rewrite_installed_at!(path, "2000-01-01T00:00:00Z")

      # A user-authored skill in the same dir: SKILL.md but NO .faber.json marker.
      users = Path.join(skills, "users-own")
      File.mkdir_p!(users)
      File.write!(Path.join(users, "SKILL.md"), "---\nname: users-own\n---\n# U\n")

      results = [result(transcript!(dir, "s1.jsonl"), 0.3, ["CASED", "users-own"])]

      assert [%{skill: "cased", sessions_used: 1}] =
               Feedback.report(dir: skills, results: results)
    end
  end
end
