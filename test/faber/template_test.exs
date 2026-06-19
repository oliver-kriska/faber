defmodule Faber.TemplateTest do
  use ExUnit.Case, async: true

  alias Faber.Template

  describe "render/2" do
    test "substitutes scalar tokens and drops unknown ones" do
      assert Template.render("{{a}}-{{b}}-{{missing}}", %{"a" => "x", "b" => 1}) == "x-1-"
    end

    test "repeats a list section once per item with item-scoped tokens" do
      out =
        Template.render(
          "{{#rows}}{{i}}:{{v}}\n{{/rows}}",
          %{"rows" => [%{"i" => 1, "v" => "a"}, %{"i" => 2, "v" => "b"}]}
        )

      assert out == "1:a\n2:b\n"
    end

    test "falsy sections (nil, false, empty list) render to nothing" do
      tmpl = "[{{#s}}x{{/s}}]"
      assert Template.render(tmpl, %{"s" => nil}) == "[]"
      assert Template.render(tmpl, %{"s" => false}) == "[]"
      assert Template.render(tmpl, %{"s" => []}) == "[]"
      assert Template.render(tmpl, %{}) == "[]"
    end

    test "a true section renders once against the current context" do
      assert Template.render("{{#on}}{{v}}{{/on}}", %{"on" => true, "v" => "hi"}) == "hi"
    end

    test "item tokens shadow the parent context inside a section" do
      out =
        Template.render("{{#rows}}{{k}}{{/rows}}", %{
          "k" => "parent",
          "rows" => [%{"k" => "child"}]
        })

      assert out == "child"
    end
  end
end
