defmodule Faber.Install.ManagedBlockTest do
  use ExUnit.Case, async: true

  alias Faber.Install.ManagedBlock, as: MB

  describe "render/1 + digest/1" do
    test "wraps the body in markers carrying the body digest" do
      block = MB.render("hello world")
      assert block =~ ~r/\A<!-- FABER:BEGIN sha256:[0-9a-f]{12} -->\n/
      assert block =~ "hello world"
      assert String.ends_with?(block, "<!-- FABER:END -->")
    end

    test "digest is stable for the same body and differs across bodies" do
      assert MB.digest("a") == MB.digest("a")
      refute MB.digest("a") == MB.digest("b")
      # whitespace-insensitive at the edges (render trims)
      assert MB.digest("a") == MB.digest("  a\n")
    end
  end

  describe "upsert/2 (idempotent, in-place)" do
    test "appends a block after a blank line when none exists, preserving user text" do
      content = "# My notes\n\nsome text"
      out = MB.upsert(content, "faber body")

      assert String.starts_with?(out, "# My notes\n\nsome text")
      assert {:ok, %{body: "faber body"}} = MB.extract(out)
    end

    test "is byte-stable: upserting the same body twice yields identical content" do
      once = MB.upsert("preamble\n", "body v1")
      twice = MB.upsert(once, "body v1")
      assert once == twice
    end

    test "replaces an existing block in place, keeping surrounding text" do
      content = "TOP\n\n" <> MB.render("old body") <> "\n\nBOTTOM\n"
      out = MB.upsert(content, "new body")

      assert {:ok, %{body: "new body"}} = MB.extract(out)
      assert out =~ "TOP"
      assert out =~ "BOTTOM"
      refute out =~ "old body"
      # exactly one block remains
      assert length(Regex.scan(~r/FABER:BEGIN/, out)) == 1
    end

    test "handles bodies containing regex-replacement metacharacters (\\0, \\1)" do
      body = "line with \\0 and \\1 and \\g{name}"
      out = MB.upsert("x", body)
      assert {:ok, %{body: ^body}} = MB.extract(out)
    end
  end

  describe "in_sync?/2 and tampered?/1" do
    test "in_sync? is true right after upsert, false for a different body" do
      out = MB.upsert("", "the body")
      assert MB.in_sync?(out, "the body")
      refute MB.in_sync?(out, "a different body")
    end

    test "in_sync?/has_block? are false when there is no block" do
      refute MB.has_block?("just user text")
      refute MB.in_sync?("just user text", "anything")
      assert MB.extract("just user text") == :none
    end

    test "tampered? detects a hand-edited block body (digest no longer matches)" do
      out = MB.upsert("", "original")
      refute MB.tampered?(out)

      # Simulate a manual edit INSIDE the block (body changed, marker digest stale).
      edited = String.replace(out, "original", "manually changed")
      assert MB.tampered?(edited)
    end
  end
end
