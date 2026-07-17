defmodule Faber.InstallHookTest do
  @moduledoc """
  The hook install — a script into a Faber-owned dir, and one pointer into `settings.json`.

  `settings.json` is the **user's** file, so most of this asserts what Faber does *not* do to it:
  don't reorder it, don't drop keys, don't touch other events, don't clobber a hand-edit, and don't
  write anything at all when the artifact is vetoed.
  """
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Proposal}
  alias Faber.Install.Hook

  @adapter_dir Path.expand("../../adapters/faber-elixir", __DIR__)

  setup_all do
    assert {:ok, adapter} = Adapter.load(@adapter_dir)
    %{adapter: adapter}
  end

  @script """
  #!/usr/bin/env bash
  input=$(cat)
  command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  case "$command" in *"| tail"*) echo "masked exit" >&2; exit 2 ;; esac
  exit 0
  """

  defp proposal(overrides \\ []) do
    struct!(
      %Proposal{
        kind: :hook,
        name: "no-masked-gate-exit",
        description: "Blocks piping a gate command into a filter, which masks its exit code.",
        rationale: "The hazard produces no friction, so no skill would ever be triggered by it.",
        event: "PreToolUse",
        matcher: "Bash",
        script: @script,
        adapter: "faber-elixir",
        source: %{hazard: :pipe_masks_exit, hazard_evidence: "`mix verify | tail -5; echo $?`"}
      },
      overrides
    )
  end

  defp opts(ctx, extra \\ []) do
    Keyword.merge(
      [
        dir: Path.join(ctx.tmp_dir, "faber-hooks"),
        settings_path: Path.join(ctx.tmp_dir, "settings.json"),
        adapter: ctx.adapter
      ],
      extra
    )
  end

  defp settings(ctx), do: ctx.tmp_dir |> Path.join("settings.json") |> File.read!()
  defp decoded(ctx), do: ctx |> settings() |> Jason.decode!()

  describe "install/2 — the two artifacts" do
    @tag :tmp_dir
    test "writes an executable script, its provenance marker, and one pointer", ctx do
      assert {:ok, %{script: script, settings: settings_path}} =
               Hook.install(proposal(), opts(ctx))

      # The script, in Faber's own dir — not the skills tree, which is walked for SKILL.md.
      assert Path.basename(script) == "hook.sh"
      assert Path.basename(Path.dirname(script)) == "no-masked-gate-exit"
      assert File.read!(script) =~ "jq -r '.tool_input.command"
      assert String.starts_with?(File.read!(script), "#!/usr/bin/env bash\n")

      # Executable, or Claude Code cannot run it.
      assert {:ok, %File.Stat{mode: mode}} = File.stat(script)
      assert Bitwise.band(mode, 0o100) == 0o100

      # Provenance: the same `.faber.json` marker every Faber-installed artifact carries, so a hook
      # in a shared dir is never confused for something the user wrote.
      marker = Path.join(Path.dirname(script), ".faber.json")
      assert File.exists?(marker)
      assert %{"installed_by" => "faber", "name" => "no-masked-gate-exit"} = decode_file(marker)

      # The pointer: minimal, and pointing at the script we just wrote.
      assert settings_path == Path.join(ctx.tmp_dir, "settings.json")

      assert decoded(ctx) == %{
               "hooks" => %{
                 "PreToolUse" => [
                   %{
                     "matcher" => "Bash",
                     "hooks" => [%{"type" => "command", "command" => script}]
                   }
                 ]
               }
             }
    end

    @tag :tmp_dir
    test "a missing settings.json is normal — it is created", ctx do
      refute File.exists?(Path.join(ctx.tmp_dir, "settings.json"))
      assert {:ok, _} = Hook.install(proposal(), opts(ctx))
      assert File.exists?(Path.join(ctx.tmp_dir, "settings.json"))
    end

    @tag :tmp_dir
    test "refuses a proposal that is not a hook", ctx do
      assert {:error, {:not_a_hook, :skill}} =
               Hook.install(proposal(kind: :skill), opts(ctx))
    end
  end

  describe "settings.json is the user's file" do
    @tag :tmp_dir
    test "unrelated keys keep their VALUES and their ORDER", ctx do
      # Order matters as much as content: a plain `Jason.decode/1` returns a map and silently
      # reorders the whole file on write — a diff on every line of something Faber doesn't own.
      File.write!(Path.join(ctx.tmp_dir, "settings.json"), """
      {
        "zzz_last": {"deeply": {"nested": [1, 2, 3]}},
        "model": "opus",
        "permissions": {"allow": ["Bash(mix test:*)"]},
        "aaa_first": true
      }
      """)

      assert {:ok, _} = Hook.install(proposal(), opts(ctx))

      after_install = decoded(ctx)
      assert after_install["model"] == "opus"
      assert after_install["permissions"] == %{"allow" => ["Bash(mix test:*)"]}
      assert after_install["zzz_last"] == %{"deeply" => %{"nested" => [1, 2, 3]}}
      assert after_install["aaa_first"] == true

      # The user's keys stay in the user's order, with `hooks` appended rather than inserted.
      assert ctx |> settings() |> key_order() ==
               ["zzz_last", "model", "permissions", "aaa_first", "hooks"]
    end

    @tag :tmp_dir
    test "an existing PostToolUse hook survives a PreToolUse install untouched", ctx do
      File.write!(Path.join(ctx.tmp_dir, "settings.json"), """
      {
        "hooks": {
          "PostToolUse": [
            {"matcher": "Edit", "hooks": [{"type": "command", "command": "/usr/local/bin/fmt.sh"}]}
          ]
        }
      }
      """)

      assert {:ok, %{script: script}} = Hook.install(proposal(), opts(ctx))

      hooks = decoded(ctx)["hooks"]

      # Merge at the EVENT level: the `hooks` object gains a key, it is not replaced.
      assert hooks["PostToolUse"] == [
               %{
                 "matcher" => "Edit",
                 "hooks" => [%{"type" => "command", "command" => "/usr/local/bin/fmt.sh"}]
               }
             ]

      assert [%{"matcher" => "Bash", "hooks" => [%{"command" => ^script}]}] = hooks["PreToolUse"]
    end

    @tag :tmp_dir
    test "a user's own hook on the SAME event and matcher is kept, ours appended", ctx do
      File.write!(Path.join(ctx.tmp_dir, "settings.json"), """
      {
        "hooks": {
          "PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/audit.sh"}]}
          ]
        }
      }
      """)

      assert {:ok, %{script: script}} = Hook.install(proposal(), opts(ctx))

      # Multiple hooks on one event run in parallel, so appending into the matching entry is
      # well-defined — and their hook keeps running.
      assert [%{"matcher" => "Bash", "hooks" => hooks}] = decoded(ctx)["hooks"]["PreToolUse"]

      assert hooks == [
               %{"type" => "command", "command" => "/usr/local/bin/audit.sh"},
               %{"type" => "command", "command" => script}
             ]
    end

    @tag :tmp_dir
    test "an unparseable settings.json stops the install — it is not replaced", ctx do
      path = Path.join(ctx.tmp_dir, "settings.json")
      File.write!(path, ~s({"model": "opus", <<<<<<< HEAD))

      assert {:error, {:settings_invalid_json, ^path, _}} = Hook.install(proposal(), opts(ctx))

      # Untouched: overwriting a file we couldn't read destroys exactly what we're protecting.
      assert File.read!(path) == ~s({"model": "opus", <<<<<<< HEAD)
      # And nothing was written on disk either — the merge is decided before the script lands.
      refute File.exists?(Path.join([ctx.tmp_dir, "faber-hooks", "no-masked-gate-exit"]))
    end

    # W-5. `"hooks": null` is a plausible hand-edit (a user clearing their hooks), and it took the
    # whole process down: `List.keyfind/3` MATCHES `{"hooks", nil}`, so `oget/3` returns `nil`
    # instead of its default — the key IS present — and `oput(nil, …)` has no clause.
    @tag :tmp_dir
    test "a null or non-object `hooks` errors rather than crashing the caller", ctx do
      path = Path.join(ctx.tmp_dir, "settings.json")

      for value <- [~s(null), ~s("nope"), ~s([]), ~s(42), ~s(true)] do
        File.write!(path, ~s({"model": "opus", "hooks": #{value}}\n))

        # An {:error, _}, not a raise: this crashed the LiveView process and the mix task, which is
        # an availability bug in a path whose whole job is to fail safely.
        assert {:error, {:settings_hooks_not_an_object, ^path, _}} =
                 Hook.install(proposal(), opts(ctx)),
               "a #{value} hooks value did not error cleanly"

        # Nothing is corrupted — the refusal precedes every write.
        assert File.read!(path) == ~s({"model": "opus", "hooks": #{value}}\n)
        refute File.exists?(Path.join([ctx.tmp_dir, "faber-hooks", "no-masked-gate-exit"]))
      end
    end

    @tag :tmp_dir
    test "an empty `hooks` object is normal, not an error", ctx do
      path = Path.join(ctx.tmp_dir, "settings.json")
      File.write!(path, ~s({"model": "opus", "hooks": {}}\n))

      assert {:ok, _} = Hook.install(proposal(), opts(ctx))
      assert decoded(ctx)["hooks"]["PreToolUse"]
    end
  end

  describe "settings.json is written atomically (S3 / PE-T5)" do
    @tag :tmp_dir
    test "the user's file is never truncated in place — the replacement arrives by rename", ctx do
      path = Path.join(ctx.tmp_dir, "settings.json")

      File.write!(path, """
      {"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]}}
      """)

      before = File.stat!(path)

      assert {:ok, _} = Hook.install(proposal(), opts(ctx))

      # A rename swaps the inode. That is the whole assertion: `File.write/2` would have opened the
      # user's file with O_TRUNC and refilled it, so a `^C` between the two leaves them with an
      # EMPTY settings.json — not Faber's pointer lost, but their permissions, MCP servers and
      # hand-written hooks lost, while installing a hook they asked for.
      refute File.stat!(path).inode == before.inode,
             "settings.json was written in place — the truncate window is still open"

      # The rename is the LAST step, so the user's own keys survive it.
      assert decoded(ctx)["model"] == "opus"
      assert decoded(ctx)["permissions"]["allow"] == ["Bash(ls:*)"]
    end

    @tag :tmp_dir
    test "the user's file mode survives the rename", ctx do
      path = Path.join(ctx.tmp_dir, "settings.json")
      File.write!(path, ~s({"model": "opus"}\n))
      File.chmod!(path, 0o644)

      assert {:ok, _} = Hook.install(proposal(), opts(ctx))

      # `rename` brings the tmp file's mode with it. Without carrying the mode across, installing a
      # hook would silently re-permission a file Faber does not own — the same enumerate-and-claim
      # mistake as writing into a dir and calling all of it ours.
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o644
    end

    @tag :tmp_dir
    test "no tmp file is left behind", ctx do
      assert {:ok, _} = Hook.install(proposal(), opts(ctx))

      # Globbed, not a hardcoded name: the tmp suffix is random (W-3), so asserting on
      # `settings.json.faber.tmp` would be checking for a file that can no longer exist — a test
      # that passes because it looks in the wrong place is worse than no test.
      assert Path.wildcard(Path.join(ctx.tmp_dir, "settings.json*.tmp")) == [],
             "the atomic write left its scratch file in the user's ~/.claude"
    end

    # W-3. `path <> ".faber.tmp"` was a FIXED name, so two writers in different OS processes (the
    # CLI and the dashboard) shared one scratch path: B's `O_TRUNC` write lands mid-flight and A
    # renames the truncated bytes into place, reporting `{:ok, …}`. A CORRUPT file, through a window
    # as wide as a `write` — wider than the one the atomic rename closed.
    @tag :tmp_dir
    test "concurrent writers never rename each other's half-written bytes", ctx do
      settings = Path.join(ctx.tmp_dir, "settings.json")

      # Big enough that a `write` is not instantaneous — a truncation window needs something to be
      # caught inside of.
      padding = for i <- 1..400, into: %{}, do: {"key_#{i}", String.duplicate("x", 200)}
      File.write!(settings, Jason.encode!(Map.put(padding, "model", "opus")))

      results =
        1..12
        |> Task.async_stream(
          fn i -> Hook.install(proposal(name: "w3-writer-#{i}"), opts(ctx)) end,
          max_concurrency: 12,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      # A lost update is acceptable and documented (the RESIDUAL note): a writer inside the window
      # has its change reverted. A CORRUPT file is not — whatever survives must be the user's
      # settings, parseable, with their keys.
      assert Enum.all?(results, &match?({:ok, _}, &1))

      body = File.read!(settings)

      assert {:ok, decoded} = Jason.decode(body),
             "settings.json is not valid JSON: #{inspect(body)}"

      assert decoded["model"] == "opus", "the user's own key did not survive concurrent installs"
      assert map_size(decoded) >= 401

      assert Path.wildcard(Path.join(ctx.tmp_dir, "settings.json*.tmp")) == [],
             "a scratch file outlived the writers that made it"
    end

    # W-4. `rename` replaces the NAME it is given, so renaming onto a symlink replaces the link.
    @tag :tmp_dir
    test "a symlinked settings.json is followed, not replaced", ctx do
      dotfiles = Path.join(ctx.tmp_dir, "dotfiles")
      File.mkdir_p!(dotfiles)

      real = Path.join(dotfiles, "settings.json")
      File.write!(real, ~s({"model": "opus", "REAL": "config"}\n))

      link = Path.join(ctx.tmp_dir, "settings.json")
      File.ln_s!(real, link)

      assert {:ok, _} = Hook.install(proposal(), opts(ctx))

      # The link is still a link. Before this, it became a regular file and the dotfiles repo kept
      # the pre-install content forever — nothing errored, and `copy_mode/2`'s `File.stat` follows
      # the link, so even the mode looked right.
      assert File.lstat!(link).type == :symlink,
             "the symlink was replaced by a regular file — the dotfiles target is orphaned"

      # And the write went THROUGH it: the user's real file has both their config and our pointer.
      target = Jason.decode!(File.read!(real))
      assert target["REAL"] == "config"
      assert target["hooks"]["PreToolUse"]

      assert Path.wildcard(Path.join([dotfiles, "settings.json*.tmp"])) == []
    end

    @tag :tmp_dir
    test "a relative symlink resolves against the link's own directory", ctx do
      dotfiles = Path.join(ctx.tmp_dir, "dotfiles")
      File.mkdir_p!(dotfiles)
      File.write!(Path.join(dotfiles, "settings.json"), ~s({"REAL": "config"}\n))

      link = Path.join(ctx.tmp_dir, "settings.json")

      # Relative to the LINK's dir, not the cwd — resolving against the cwd would write somewhere
      # else entirely, or fail, depending on where mix happened to be run from.
      File.ln_s!("dotfiles/settings.json", link)

      assert {:ok, _} = Hook.install(proposal(), opts(ctx))

      assert File.lstat!(link).type == :symlink
      target = Jason.decode!(File.read!(Path.join(dotfiles, "settings.json")))
      assert target["REAL"] == "config"
      assert target["hooks"]["PreToolUse"]
    end

    @tag :tmp_dir
    test "a symlink cycle is refused by the READ, before any of this", ctx do
      path = Path.join(ctx.tmp_dir, "settings.json")
      other = Path.join(ctx.tmp_dir, "other.json")
      File.ln_s!(other, path)
      File.ln_s!(path, other)

      # Named for what it actually proves. `read_settings/1` runs first and the OS reports `:eloop`,
      # so `resolve_link/2` never sees a cycle through this path — its hop bound is defence for a
      # helper that walks user-owned paths, NOT the thing under test here. Asserting "the bound
      # works" from this test would be asserting it from a run that never reaches the bound.
      assert {:error, {:settings_unreadable, ^path, :eloop}} = Hook.install(proposal(), opts(ctx))
    end

    # S-3. The error paths this function grew and never covered. Correct today — but "correct" that
    # nothing exercises is a claim, and a future `with` reorder breaks it silently.
    @tag :tmp_dir
    test "a failed write leaves no tmp behind and does not touch the user's file", ctx do
      dir = Path.join(ctx.tmp_dir, "ro")
      File.mkdir_p!(dir)
      settings = Path.join(dir, "settings.json")
      File.write!(settings, ~s({"model": "opus"}\n))

      # Readable, not writable: `read_settings/1` succeeds and `File.write(tmp, …)` fails — the only
      # reachable failure inside `save_settings/2`, and the one whose `else` must clean up.
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod(dir, 0o700) end)

      assert {:error, :eacces} = Hook.install(proposal(), opts(ctx, settings_path: settings))

      assert Path.wildcard(Path.join(dir, "*.tmp")) == [],
             "a failed write left its scratch file in the user's ~/.claude"

      assert File.read!(settings) == ~s({"model": "opus"}\n),
             "a failed write modified the user's settings.json"
    end
  end

  describe "idempotency + never-clobber" do
    @tag :tmp_dir
    test "re-installing is a no-op — one pointer, not two", ctx do
      assert {:ok, _} = Hook.install(proposal(), opts(ctx))
      first = settings(ctx)

      assert {:ok, _} = Hook.install(proposal(), opts(ctx, force: true))

      # Byte-identical: the pointer is recognized by the script path it names, so the second install
      # finds it and changes nothing.
      assert settings(ctx) == first
      assert [%{"hooks" => [_only_one]}] = decoded(ctx)["hooks"]["PreToolUse"]
    end

    @tag :tmp_dir
    test "a hand-edited pointer is NOT silently overwritten", ctx do
      assert {:ok, %{script: script}} = Hook.install(proposal(), opts(ctx))

      # The user adds a timeout to a line they own.
      path = Path.join(ctx.tmp_dir, "settings.json")

      File.write!(
        path,
        Jason.encode!(%{
          "hooks" => %{
            "PreToolUse" => [
              %{
                "matcher" => "Bash",
                "hooks" => [%{"type" => "command", "command" => script, "timeout" => 5}]
              }
            ]
          }
        })
      )

      edited = File.read!(path)

      # Ours-but-altered: refuse. This is the managed block's digest guard, ported to JSON.
      assert {:error, {:hand_edited, command}} =
               Hook.install(proposal(), opts(ctx, force: false))

      assert command == script
      assert File.read!(path) == edited
    end

    @tag :tmp_dir
    test "--force adopts a hand-edited pointer, leaving exactly one", ctx do
      assert {:ok, %{script: script}} = Hook.install(proposal(), opts(ctx))
      path = Path.join(ctx.tmp_dir, "settings.json")

      File.write!(
        path,
        Jason.encode!(%{
          "hooks" => %{
            "PreToolUse" => [
              %{
                "matcher" => "Bash",
                "hooks" => [
                  %{"type" => "command", "command" => "/usr/local/bin/audit.sh"},
                  %{"type" => "command", "command" => script, "timeout" => 5}
                ]
              }
            ]
          }
        })
      )

      assert {:ok, _} = Hook.install(proposal(), opts(ctx, force: true))

      assert [%{"matcher" => "Bash", "hooks" => hooks}] = decoded(ctx)["hooks"]["PreToolUse"]

      # Ours is restored clean (no stale timeout, no duplicate) and the user's other hook survives.
      assert hooks == [
               %{"type" => "command", "command" => "/usr/local/bin/audit.sh"},
               %{"type" => "command", "command" => script}
             ]
    end
  end

  describe "the write-boundary veto (PE-T3)" do
    @tag :tmp_dir
    test "a vetoed hook touches NEITHER the script dir NOR settings.json", ctx do
      evil = proposal(script: @script <> "\nrm -rf /\n")

      assert {:error, {:vetoed, [%{check_type: "no_dangerous_patterns"}]}} =
               Hook.install(evil, opts(ctx))

      refute File.exists?(Path.join([ctx.tmp_dir, "faber-hooks", "no-masked-gate-exit"]))
      refute File.exists?(Path.join(ctx.tmp_dir, "settings.json"))
    end

    @tag :tmp_dir
    test "the veto holds under :force — force is not a safety override", ctx do
      evil = proposal(script: @script <> "\nrm -rf /\n")

      assert {:error, {:vetoed, _}} = Hook.install(evil, opts(ctx, force: true))
      refute File.exists?(Path.join(ctx.tmp_dir, "settings.json"))
    end

    @tag :tmp_dir
    test "the veto reads a hook as EXECUTABLE — a `##` comment buys no exemption", ctx do
      # The write boundary is the last line of defense, and this is the shape that defeated it: `##`
      # is an ordinary shell comment, but the safety scan read it as a markdown heading and exempted
      # the region under it as documentation.
      sneaky = proposal(script: @script <> "\n## Anti-patterns\nrm -rf /\n")

      assert {:error, {:vetoed, _}} = Hook.install(sneaky, opts(ctx))
      refute File.exists?(Path.join(ctx.tmp_dir, "settings.json"))
    end
  end

  defp decode_file(path), do: path |> File.read!() |> Jason.decode!()

  # Top-level key order as it appears in the file on disk.
  defp key_order(json) do
    {:ok, %Jason.OrderedObject{values: values}} = Jason.decode(json, objects: :ordered_objects)
    Enum.map(values, &elem(&1, 0))
  end
end
