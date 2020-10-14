defmodule ESpec.Before do
  @moduledoc """
  Defines 'before' macro.
  If before block returns {:ok, key: value},
  the {key, value} is added to an 'exapmle dict'.
  The dict can be accessed in another `before`, in `let`,
  and in example by `shared` (`shared[:key]`).
  """

  @doc "Struct has 'spec' module name and random function name."
  defstruct module: nil, function: nil

  @doc """
  Adds %ESpec.Before structs to the @context and
  defines a function with random name which will be called when example is run.
  """
  defmacro before(do: block), do: do_before(block)

  defmacro before(keyword) when is_list(keyword) do
    if Keyword.keyword?(keyword) do
      do_before({:shared, keyword})
    else
      raise "Argument must be a Keyword"
    end
  end

  defp do_before(block) do
    function = random_before_name()

    quote do
      tail = @context
      head = %ESpec.Before{module: __MODULE__, function: unquote(function)}

      def unquote(function)(var!(shared)) do
        var!(shared)
        unquote(block)
      end

      @context [head | tail]
    end
  end

  defp random_before_name, do: String.to_atom("before_#{ESpec.Support.random_string()}")
end
