defmodule ESpec.DocTestTest.SomeDocSpec do
  use ESpec
  doctest TestModules.Docs.DocTestModules.Mod1
end
|> ExUnit.TestHelpers.write_beam()

defmodule ESpec.Docs.DocTestTest do
  use ExUnit.Case, async: true

  setup do
    examples = ESpec.DocTestTest.SomeDocSpec.examples()

    {:ok,
     ex1: Enum.at(examples, 0),
     ex2: Enum.at(examples, 1),
     ex3: Enum.at(examples, 2),
     ex4: Enum.at(examples, 3)}
  end

  test "ex1", context do
    ex = ESpec.ExampleRunner.run(context[:ex1])
    assert ex.description =~ "Doctest for Elixir.TestModules.Docs.DocTestModules.Mod1.moduledoc/0"
    assert ex.status == :success
    assert ex.result == "`4` equals `4`."
  end

  test "ex2", context do
    ex = ESpec.ExampleRunner.run(context[:ex2])
    assert ex.description =~ "Doctest for Elixir.TestModules.Docs.DocTestModules.Mod1.f/0"
    assert ex.status == :success
    assert ex.result == "`[2, 4, 6]` equals `[2, 4, 6]`."
  end

  test "ex3", context do
    ex = ESpec.ExampleRunner.run(context[:ex3])
    assert ex.description =~ "Doctest for Elixir.TestModules.Docs.DocTestModules.Mod1.f/0"
    assert ex.status == :failure
    assert ex.error.message == "Expected `4` to equal (==) `5`, but it doesn't."
  end

  test "ex4", context do
    ex = ESpec.ExampleRunner.run(context[:ex4])
    assert ex.status == :success
    assert ex.result == "`:f` equals `:f`."
  end
end
