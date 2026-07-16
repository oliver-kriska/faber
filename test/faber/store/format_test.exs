defmodule Faber.Store.FormatTest do
  use ExUnit.Case, async: true

  # Compiling a module that misuses the behaviour must FAIL. These tests compile a string at
  # runtime so the failure is catchable — `Code.compile_string/1` raises the same ArgumentError the
  # macro would raise during a normal `mix compile`.
  defp compile(body) do
    Code.compile_string("""
    defmodule Faber.Store.FormatTest.Gen#{System.unique_integer([:positive])} do
      #{body}
    end
    """)
  end

  describe "the compile-time assertions bite" do
    test "a store that cannot read the format it writes fails to compile" do
      err =
        assert_raise ArgumentError, fn ->
          compile("""
          use Faber.Store.Format,
            format: 2, readable_formats: [1], data_class: :derived, unstamped: :unreadable
          """)
        end

      assert err.message =~ "writes format 2 but cannot read it"
    end

    test "a paid store that drops a format it has written fails to compile" do
      # THE BUG THIS MODULE EXISTS TO PREVENT: bump the version, forget the old records.
      err =
        assert_raise ArgumentError, fn ->
          compile("""
          use Faber.Store.Format,
            format: 3, readable_formats: [2, 3], data_class: :paid, unstamped: :unreadable
          """)
        end

      assert err.message =~ "drops format(s) [1]"
      assert err.message =~ "the user paid for it"
    end

    test "a derived store MAY drop old formats — dropping costs a rescan, not money" do
      assert compile("""
             use Faber.Store.Format,
               format: 3, readable_formats: [3], data_class: :derived, unstamped: :unreadable
             """)
    end

    test "every part of the declaration is required — none of it has a safe default" do
      for {opts, missing} <- [
            {"readable_formats: [1], data_class: :paid, unstamped: 1", ":format"},
            {"format: 1, data_class: :paid, unstamped: 1", ":readable_formats"},
            {"format: 1, readable_formats: [1], unstamped: 1", ":data_class"},
            {"format: 1, readable_formats: [1], data_class: :paid", ":unstamped"}
          ] do
        err = assert_raise ArgumentError, fn -> compile("use Faber.Store.Format, #{opts}") end
        assert err.message =~ missing
      end
    end

    test "an unknown data class fails to compile" do
      assert_raise ArgumentError, ~r/:data_class must be one of/, fn ->
        compile("""
        use Faber.Store.Format,
          format: 1, readable_formats: [1], data_class: :vibes, unstamped: 1
        """)
      end
    end

    test "an :unstamped naming an unreadable format fails to compile" do
      # Otherwise the policy is a no-op that reads as an intention: "unstamped records are v1"
      # while v1 isn't readable means unstamped records are still silently dropped.
      assert_raise ArgumentError, ~r/:unstamped must be :unreadable or a format/, fn ->
        compile("""
        use Faber.Store.Format,
          format: 2, readable_formats: [2], data_class: :derived, unstamped: 1
        """)
      end
    end

    test "a malformed version or readable list fails to compile" do
      assert_raise ArgumentError, ~r/:format must be a positive integer/, fn ->
        compile("""
        use Faber.Store.Format,
          format: "2", readable_formats: [1], data_class: :paid, unstamped: 1
        """)
      end

      assert_raise ArgumentError, ~r/:readable_formats must be a non-empty list/, fn ->
        compile("""
        use Faber.Store.Format,
          format: 1, readable_formats: [], data_class: :paid, unstamped: :unreadable
        """)
      end
    end
  end

  defmodule PaidStore do
    use Faber.Store.Format,
      format: 2,
      readable_formats: [1, 2],
      data_class: :paid,
      unstamped: :unreadable
  end

  defmodule DerivedStore do
    use Faber.Store.Format,
      format: 1,
      readable_formats: [1],
      data_class: :derived,
      unstamped: 1
  end

  describe "the generated declaration" do
    test "reports what it writes, what it reads, and what it holds" do
      assert PaidStore.format() == 2
      assert PaidStore.readable_formats() == [1, 2]
      assert PaidStore.data_class() == :paid
      assert PaidStore.unstamped() == :unreadable
    end

    test "readable?/1 accepts every declared format and rejects the rest" do
      assert PaidStore.readable?(1)
      assert PaidStore.readable?(2)
      refute PaidStore.readable?(3)
      refute PaidStore.readable?(0)
    end

    test "an unstamped record reads as v1 where records predate the key" do
      # Journals and markers already exist on Oliver's real disk with no format key. A reader that
      # demanded the key would orphan every one of them — the same bug class this module prevents.
      assert DerivedStore.unstamped() == 1
      assert DerivedStore.readable?(nil)
    end

    test "an unstamped record is unreadable where the store always stamped" do
      # PaidStore stamped from v1 onward, so a file with no version did not come from it. Reading
      # it would invent a record out of whatever keys happened to parse.
      refute PaidStore.readable?(nil)
    end

    test "a non-integer version is not readable (a hand-edited or corrupt record)" do
      refute PaidStore.readable?("2")
      refute PaidStore.readable?(:two)
      refute PaidStore.readable?(2.0)
    end

    test "a derived store that reads only its own format drops every other stamp" do
      refute DerivedStore.readable?(2)
    end
  end
end
