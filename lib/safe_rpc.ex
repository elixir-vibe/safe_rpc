defmodule SafeRPC do
  @moduledoc "GenServer-like RPC over Erlang external term format for explicit, capability-scoped APIs."

  alias SafeRPC.Client

  defdelegate call(socket, op, payload \\ %{}, opts \\ []), to: Client
  defdelegate cast(socket, op, payload \\ %{}, opts \\ []), to: Client

  def async(client, op, payload \\ %{}, opts \\ []) do
    case Client.send_request(client, op, payload, opts) do
      {:ok, request} -> request
      {:error, reason} -> raise RuntimeError, "SafeRPC async request failed: #{inspect(reason)}"
    end
  end

  def await(%SafeRPC.Task{id: id} = request, timeout \\ 5_000) do
    receive do
      {SafeRPC.Task, ^id, result} -> result
    after
      timeout -> exit({:timeout, {__MODULE__, :await, [request, timeout]}})
    end
  end

  def yield(%SafeRPC.Task{id: id}, timeout \\ 0) do
    receive do
      {SafeRPC.Task, ^id, result} -> {:ok, result}
    after
      timeout -> nil
    end
  end

  def shutdown(%SafeRPC.Task{}, _timeout \\ 5_000), do: nil
end
