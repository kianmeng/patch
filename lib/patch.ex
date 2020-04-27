defmodule Patch do
  @moduledoc """
  Patch - Ergonomic Mocking for Elixir

  Patch makes it easy to mock one or more functions in a module returning a value or executing
  custom logic.  Patches and Spies allow tests to assert or refute that function calls have been
  made.

  ## Patches

  When a module is patched, the patched function will return the value provided.

  ```elixir
  assert "HELLO" = String.upcase("hello")                 # Assertion passes before patching

  patch(String, :upcase, :patched_return_value)

  assert :patched_return_value == String.upcase("hello")  # Assertion passes after patching
  ```

  Modules can also be patched to run custom logic instead of returning a static value

  ```elixir
  assert "HELLO" = String.upcase("hello")                 # Assertion passes before patching

  patch(String, :upcase, fn s -> String.length(s) end)

  assert 5 == String.upcase("hello")                      # Assertion passes after patching
  ```

  ### Patching Ergonomics

  `patch/3` returns the value that the patch will return which can be useful for later on in the
  test.  Examine this example code for an example

  ```elixir
  {:ok, expected} = patch(My.Module, :some_function, {:ok, 123})

  ... additional testing code ...

  assert response.some_function_result == expected
  ```

  This allows the test author to combine creating fixture data with patching.

  ## Asserting / Refuting Calls

  After a patch is applied, tests can assert that an expected call has occurred by using the
  `assert_called` macro.

  ```elixir
  patch(String, :upcase, :patched_return_value)

  assert :patched_return_value = String.upcase("hello")   # Assertion passes after patching

  assert_called String.upcase("hello")                    # Assertion passes after call
  ```

  `assert_called` supports the `:_` wildcard atom.  In the above example the following assertion
  would also pass.

  ```elixir
  assert_called String.upcase(:_)
  ```

  This can be useful when some of the arguments are complex or uninteresting for the unit test.

  Tests can also refute that a call has occurred with the `refute_called` macro.  This macro works
  in much the same way as `assert_called` and also supports the `:_` wildcard atom.

  ## Spies

  If a test wishes to assert / refute calls that happen to a module without actually changing the
  behavior of the module it can simply `spy/1` the module.  Spies behave identically to the
  original module but all calls and return values are recorded so assert_called and refute_called
  work as expected.

  ## Limitations

  Patch currently can only mock out functions of arity /0 - /10.  If a function with greater arity
  needs to be patched this module will need to be updated.
  """

  defmodule MissingCall do
    defexception [:message]
  end

  defmodule UnexpectedCall do
    defexception [:message]
  end

  defmacro __using__(_) do
    quote do
      require unquote(__MODULE__)
      import unquote(__MODULE__)

      setup do
        on_exit(fn ->
          :meck.unload()
        end)
      end
    end
  end

  defmacro assert_called({{:., _, [module, function]}, _, args}) do
    quote do
      value = :meck.called(unquote(module), unquote(function), unquote(args))

      unless value do
        calls =
          unquote(module)
          |> :meck.history()
          |> Enum.with_index(1)
          |> Enum.map(fn {{_, {m, f, a}, ret}, i} ->
            "#{i}. #{inspect(m)}.#{f}(#{a |> Enum.map(&Kernel.inspect/1) |> Enum.join(",")}) -> #{
              inspect(ret)
            }"
          end)
          |> Enum.join("\n")

        call_args = unquote(args) |> Enum.map(&Kernel.inspect/1) |> Enum.join(",")

        message = """
        \n
        Expected but did not receive the following call:

           #{inspect(unquote(module))}.#{to_string(unquote(function))}(#{call_args})

        Calls which were received:

        #{calls}
        """

        raise MissingCall, message: message
      end
    end
  end

  defmacro refute_called({{:., _, [module, function]}, _, args}) do
    quote do
      value = :meck.called(unquote(module), unquote(function), unquote(args))

      if value do
        calls =
          unquote(module)
          |> :meck.history()
          |> Enum.with_index(1)
          |> Enum.map(fn {{_, {m, f, a}, ret}, i} ->
            "#{i}. #{inspect(m)}.#{f}(#{a |> Enum.map(&Kernel.inspect/1) |> Enum.join(",")}) -> #{
              inspect(ret)
            }"
          end)
          |> Enum.join("\n")

        call_args = unquote(args) |> Enum.map(&Kernel.inspect/1) |> Enum.join(",")

        message = """
        \n
        Unexpected call received:

           #{inspect(unquote(module))}.#{to_string(unquote(function))}(#{call_args})

        Calls which were received:

        #{calls}
        """

        raise UnexpectedCall, message: message
      end
    end
  end

  @doc """
  Spies on the provided module

  Once a module has been spied on the calls to that module can be asserted / refuted without
  changing the behavior of the module.
  """
  @spec spy(module) :: :ok
  def spy(module) do
    ensure_mocked(module)
    :ok
  end

  @doc """
  Patches a function in a module

  The patched function will either always return the provided value or if a function is provided
  then the function will be called and its result returned.
  """
  @spec patch(module, function, mock) :: mock when mock: function
  def patch(module, function, mock) when is_function(mock) do
    ensure_mocked(module)

    :meck.expect(module, function, mock)

    mock
  end

  @spec patch(module, function, return_value) :: return_value when return_value: term
  def patch(module, function, return_value) do
    ensure_mocked(module)

    module
    |> find_arities(function)
    |> Enum.each(fn arity ->
      :meck.expect(module, function, func(arity, return_value))
    end)

    return_value
  end

  def restore(module) do
    if :meck.validate(module), do: :meck.unload(module)
  rescue
    _ in ErlangError ->
      :ok
  end

  ## Private

  defp ensure_mocked(module) do
    :meck.validate(module)
  rescue
    _ in ErlangError ->
      :meck.new(module, [:passthrough])
  end

  defp find_arities(module, function) do
    Code.ensure_loaded(module)
    Enum.filter(0..10, &function_exported?(module, function, &1))
  end

  defp func(0, return_value) do
    fn -> return_value end
  end

  defp func(1, return_value) do
    fn _ -> return_value end
  end

  defp func(2, return_value) do
    fn _, _ -> return_value end
  end

  defp func(3, return_value) do
    fn _, _, _ -> return_value end
  end

  defp func(4, return_value) do
    fn _, _, _, _ -> return_value end
  end

  defp func(5, return_value) do
    fn _, _, _, _, _ -> return_value end
  end

  defp func(6, return_value) do
    fn _, _, _, _, _, _ -> return_value end
  end

  defp func(7, return_value) do
    fn _, _, _, _, _, _, _ -> return_value end
  end

  defp func(8, return_value) do
    fn _, _, _, _, _, _, _, _ -> return_value end
  end

  defp func(9, return_value) do
    fn _, _, _, _, _, _, _, _, _ -> return_value end
  end

  defp func(10, return_value) do
    fn _, _, _, _, _, _, _, _, _, _ -> return_value end
  end
end