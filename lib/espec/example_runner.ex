defmodule ESpec.ExampleRunner do
  @moduledoc """
  Contains all the functions need to run a 'spec' example.
  """

  defmodule(AfterExampleError, do: defexception(example_error: nil, message: nil))

  @dict_keys [:ok, :shared]

  alias ESpec.Example
  alias ESpec.AssertionError
  alias ESpec.Output

  @doc """
  Runs one specific example and returns an `%ESpec.Example{}` struct.
  The sequence in the following:
  - evaluates 'befores' and 'lets'. 'befores' fill the map for `shared`, 'lets' can access `shared` ;
  - runs 'example block';
  - evaluate 'finally's'
  The struct has fields `[status: :success, result: result]` or `[status: failed, error: error]`
  The `result` is the value returned by example block.
  `error` is a `%ESpec.AssertionError{}` struct.
  """
  def run(example) do
    contexts = Example.extract_contexts(example)

    cond do
      example.opts[:skip] || Enum.any?(contexts, & &1.opts[:skip]) ->
        run_skipped(example)

      example.opts[:pending] ->
        run_pending(example)

      true ->
        spawn_example(example, :os.timestamp())
    end
  end

  defp spawn_example(example, start_time) do
    Task.Supervisor.async_nolink(ESpec.TaskSupervisor, fn -> run_example(example, start_time) end)
    |> Task.yield(:infinity)
    |> check_example_task(example, start_time)
  end

  defp check_example_task({:ok, example_result}, _, _), do: example_result

  defp check_example_task({:exit, reason}, example, start_time) do
    error = %AssertionError{message: "Process exited with reason: #{inspect(reason)}"}
    do_rescue(example, %{}, start_time, error, false)
  end

  defp run_example(example, start_time) do
    {assigns, example} = before_example_actions(example)

    try do
      try_run(example, assigns, start_time)
    rescue
      error in [AssertionError] ->
        do_rescue(example, assigns, start_time, error)

      error in [AfterExampleError] ->
        do_rescue(example, assigns, start_time, error.example_error, false)

      other_error ->
        error = %AssertionError{message: format_other_error(other_error, __STACKTRACE__)}
        do_rescue(example, assigns, start_time, error)
    catch
      what, value -> do_catch(example, assigns, start_time, what, value)
    after
      unload_mocks()
    end
  end

  defp initial_shared(example), do: Example.extract_options(example)

  defp before_example_actions(example) do
    {initial_shared(example), example}
    |> run_config_before
    |> run_befores_and_lets
  end

  defp try_run(example, assigns, start_time) do
    if example.status == :failure, do: raise(example.error)

    result =
      case apply(example.module, example.function, [assigns]) do
        {ESpec.ExpectTo, res} -> res
        res -> res
      end

    {_assigns, example} = after_example_actions(assigns, example)
    if example.status == :failure, do: raise(%AfterExampleError{example_error: example.error})

    duration = duration_in_ms(start_time, :os.timestamp())
    example = %Example{example | status: :success, result: result, duration: duration}
    Output.example_finished(example)
    example
  end

  defp do_catch(example, assigns, start_time, what, value) do
    duration = duration_in_ms(start_time, :os.timestamp())
    error = %AssertionError{message: format_catch(what, value)}
    example = %Example{example | status: :failure, error: error, duration: duration}
    Output.example_finished(example)
    after_example_actions(assigns, example)
    example
  end

  defp do_rescue(example, assigns, start_time, error, perform_after_example \\ true) do
    duration = duration_in_ms(start_time, :os.timestamp())
    example = %Example{example | status: :failure, error: error, duration: duration}
    Output.example_finished(example)
    if perform_after_example, do: after_example_actions(assigns, example)
    example
  end

  def after_example_actions(assigns, example) do
    {assigns, example}
    |> run_finallies
    |> run_config_finally
  end

  defp run_skipped(example) do
    example = %Example{example | status: :pending, result: Example.skip_message(example)}
    Output.example_finished(example)
    example
  end

  defp run_pending(example) do
    example = %Example{example | status: :pending, result: Example.pending_message(example)}
    Output.example_finished(example)
    example
  end

  defp run_config_before({assigns, example}) do
    func = ESpec.Configuration.get(:before)

    if func do
      fun =
        if is_function(func, 1) do
          fn -> {fill_dict(assigns, func.(assigns)), example} end
        else
          fn -> {fill_dict(assigns, func.()), example} end
        end

      call_with_rescue(fun, {assigns, example})
    else
      {assigns, example}
    end
  end

  defp run_befores_and_lets({assigns, example}) do
    ESpec.Let.Impl.clear_lets(example.module)

    Example.extract_lets(example)
    |> Enum.each(&ESpec.Let.Impl.run_before/1)

    {assigns, example} =
      Example.extract_befores(example)
      |> Enum.reduce({assigns, example}, fn before, {assigns, example} ->
        ESpec.Let.Impl.update_shared(assigns)
        fun = fn -> {do_run_before(before, assigns), example} end
        call_with_rescue(fun, {assigns, example})
      end)

    ESpec.Let.Impl.update_shared(assigns)

    {assigns, example}
  end

  defp run_finallies({assigns, example}) do
    Example.extract_finallies(example)
    |> Enum.reverse()
    |> Enum.reduce({assigns, example}, fn finally, {map, example} ->
      fun = fn ->
        assigns = apply(finally.module, finally.function, [map])
        {fill_dict(map, assigns), example}
      end

      call_with_rescue(fun, {assigns, example})
    end)
  end

  defp run_config_finally({assigns, example}) do
    func = ESpec.Configuration.get(:finally)

    if func do
      run_config_finally({assigns, example}, func)
    else
      {assigns, example}
    end
  end

  defp run_config_finally({assigns, example}, func) do
    fun = fn ->
      if is_function(func, 1), do: func.(assigns), else: func.()
      {assigns, example}
    end

    call_with_rescue(fun, {assigns, example})
  end

  defp call_with_rescue(fun, {assigns, example}) do
    try do
      fun.()
    rescue
      any_error -> do_before(any_error, {assigns, example}, __STACKTRACE__)
    catch
      what, value -> do_catch(what, value, {assigns, example})
    end
  end

  defp do_catch(what, value, {map, example}) do
    example =
      if example.error do
        example
      else
        error = %AssertionError{message: format_catch(what, value)}
        %Example{example | status: :failure, error: error}
      end

    {map, example}
  end

  defp do_before(error, {map, example}, stacktrace) do
    example =
      if example.error do
        example
      else
        error = %AssertionError{message: format_other_error(error, stacktrace)}
        %Example{example | status: :failure, error: error}
      end

    {map, example}
  end

  defp do_run_before(%ESpec.Before{} = before, map) do
    returned = apply(before.module, before.function, [map])
    fill_dict(map, returned)
  end

  defp fill_dict(map, res) do
    case res do
      {key, list} when key in @dict_keys and (is_list(list) or is_map(list)) ->
        if (Keyword.keyword?(list) || is_map(list)) && Enumerable.impl_for(list) do
          Enum.reduce(list, map, fn {k, v}, a -> Map.put(a, k, v) end)
        else
          map
        end

      _ ->
        map
    end
  end

  defp unload_mocks, do: ESpec.Mock.unload()

  defp duration_in_ms(start_time, end_time) do
    div(:timer.now_diff(end_time, start_time), 1000)
  end

  defp format_other_error(error, stacktrace) do
    Exception.format_banner(:error, error) <> "\n" <> Exception.format_stacktrace(stacktrace)
  end

  defp format_catch(what, value), do: "#{what} #{inspect(value)}"
end
