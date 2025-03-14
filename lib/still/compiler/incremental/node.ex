defmodule Still.Compiler.Incremental.Node do
  @moduledoc """
  An incremental node represents a file that is processed individually.

  Incremental nodes attempt to compile/render a file synchronously. This process
  can take a long time, which is usually fine, but the default timeout can be changed
  in the`:compilation_timeout` key in your `config/config.exs`. Default is
  `:infinity`.
  """

  use GenServer

  alias Still.Compiler.PreprocessorError

  require Logger

  @default_compilation_timeout :infinity

  def start_link(file: file) do
    GenServer.start_link(__MODULE__, %{file: file}, name: file |> String.to_atom())
  end

  @doc """
  Compiles the file mapped by the `Node` with the given PID.

  This PID can be obtained from `Still.Compiler.Incremental.Registry`.
  """
  def compile(pid, opts \\ []) do
    GenServer.call(pid, {:compile, opts}, compilation_timeout())
  end

  @doc """
  Renders the file mapped by the `Node` with the given PID.

  This PID can be obtained from `Still.Compiler.Incremental.Registry`.
  """
  def render(pid, data) do
    GenServer.call(pid, {:render, data}, compilation_timeout())
  end

  @doc """
  Compiles the metadata of the file mapped by the `Node` with the given PID.

  This PID can be obtained from `Still.Compiler.Incremental.Registry`.
  """
  def compile_metadata(pid, opts \\ []) do
    GenServer.call(pid, {:compile_metadata, opts}, compilation_timeout())
  end

  @doc """
  Returns the compilation timeout defined in the config.

  You can change this by setting

    config :still, :compilation_timeout, 1_000_000
  """
  def compilation_timeout do
    Still.Utils.config(:compilation_timeout, @default_compilation_timeout)
  end

  @impl true
  def init(%{file: file}) do
    state = %{
      file: file,
      subscribers: [],
      subscriptions: [],
      cached_source_file: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({_, use_cache: true}, _from, %{cached_source_file: source_file} = state)
      when not is_nil(source_file) do
    {:reply, source_file, state}
  end

  def handle_call({:compile, opts}, from, state) do
    froms = all_waiting_compile([from])
    run_type = Keyword.get(opts, :run_type, :compile)

    try do
      source_file = __MODULE__.Compile.run(state.file, run_type)

      Enum.each(froms, &GenServer.reply(&1, source_file))

      {:noreply, %{state | cached_source_file: %{source_file | content: nil}}}
    catch
      _, %PreprocessorError{} ->
        Enum.each(froms, &GenServer.reply(&1, :ok))

        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:render, data}, _from, state) do
    source_file = __MODULE__.Render.run(state.file, data)

    {:reply, source_file, state}
  catch
    _, %PreprocessorError{} = error ->
      {:reply, error, state}
  end

  @impl true
  def handle_call({:compile_metadata, _opts}, _from, state) do
    source_file = __MODULE__.Compile.run(state.file, :compile_metadata)

    {:reply, source_file, %{state | cached_source_file: %{source_file | content: nil}}}
  catch
    _, %PreprocessorError{} ->
      {:reply, :ok, state}
  end

  defp all_waiting_compile(acc) do
    receive do
      {:"$gen_call", from, {:compile, _}} -> all_waiting_compile([from | acc])
    after
      0 -> acc
    end
  end
end
