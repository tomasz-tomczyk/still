defmodule Still.Watcher do
  @moduledoc """
  File system watcher that triggers compilation for new files, recompilation for
  changed files and kills ane `Still.Compiler.Incremental.Node` for removed
  files. Should only be used in the `dev` environment.
  """

  use GenServer

  alias Still.Compiler.{
    Collections,
    ContentCache,
    ErrorCache,
    Incremental,
    Traverse
  }

  alias Still.Data

  alias Still.Web.BrowserSubscriptions

  import Still.Utils

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{}, {:continue, :async_compile}}
  end

  @doc """
  Starts the file system watcher and the compiler traversal via
  `Still.Compiler.Traverse`.
  """
  @impl true
  def handle_continue(:async_compile, state) do
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [get_input_path()])
    FileSystem.subscribe(watcher_pid)

    Data.load()
    Traverse.run(&compile_file_metadata/1)

    {:noreply, state}
  end

  @doc """
  Handles file events, triggering compilation for new files, recompilation for
  modifications and removal of `Still.Compiler.Incremental.Node` for deletions.
  """
  def handle_info({:file_event, _watcher_pid, {file, events}}, state) do
    cond do
      ignored_file?(get_relative_input_path(file)) ->
        nil

      Enum.member?(events, :removed) or Enum.member?(events, :renamed) ->
        remove_file(file)

      Enum.member?(events, :modified) ->
        process_file(file)

      Enum.member?(events, :created) ->
        process_file(file)

      true ->
        nil
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:noreply, state}
  end

  defp remove_file(file) do
    file = get_relative_input_path(file)

    if Data.member?(file) do
      Data.load()
    else
      Collections.reset()
      Traverse.run(&compile_file_metadata/1)

      ErrorCache.clear(file)
      Incremental.Registry.terminate_file_process(file)
    end

    BrowserSubscriptions.notify()
  end

  defp process_file(file) do
    file = get_relative_input_path(file)

    if Data.member?(file) do
      Data.load()
    else
      compile_file_metadata(file)

      ContentCache.clear(file)
    end

    BrowserSubscriptions.notify()
  end
end
