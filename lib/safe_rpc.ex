defmodule SafeRPC do
  @moduledoc "GenServer-like RPC over Erlang external term format for explicit, capability-scoped APIs."

  alias SafeRPC.Client

  defdelegate call(socket, op, payload \\ %{}, opts \\ []), to: Client
  defdelegate cast(socket, op, payload \\ %{}, opts \\ []), to: Client

  def async(client, op, payload \\ %{}, opts \\ []) do
    task = Task.async(fn -> call(client, op, payload, opts) end)
    %SafeRPC.Task{task: task, op: op}
  end

  def await(%SafeRPC.Task{task: task}, timeout \\ 5_000), do: Task.await(task, timeout)

  def yield(%SafeRPC.Task{task: task}, timeout \\ 0), do: Task.yield(task, timeout)

  def shutdown(%SafeRPC.Task{task: task}, timeout \\ 5_000), do: Task.shutdown(task, timeout)
end
