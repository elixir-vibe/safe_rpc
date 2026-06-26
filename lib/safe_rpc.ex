defmodule SafeRPC do
  @moduledoc "GenServer-like RPC over Erlang external term format for explicit, capability-scoped APIs."

  alias SafeRPC.Client

  @type local_binding :: %{
          required(:socket) => Path.t(),
          optional(:modules) => [module()],
          optional(:listener) => atom() | String.t(),
          optional(:unit) => String.t(),
          optional(:upstream) => String.t(),
          optional(atom()) => term()
        }

  @type local_bindings :: %{optional(atom() | String.t()) => local_binding()}

  @describe_op :safe_rpc_describe
  @atoms_op :safe_rpc_atoms

  defmacro __using__(opts) do
    quote do
      use SafeRPC.Service, unquote(opts)
    end
  end

  defdelegate call(socket, op, payload \\ %{}, opts \\ []), to: Client
  defdelegate cast(socket, op, payload \\ %{}, opts \\ []), to: Client

  def describe(socket_or_client, opts \\ []) do
    ensure_application_loaded(:safe_rpc)
    call(socket_or_client, @describe_op, Keyword.get(opts, :filter, %{}), opts)
  end

  def atoms(socket_or_client, opts \\ []) do
    call(socket_or_client, @atoms_op, Keyword.get(opts, :filter, %{}), opts)
  end

  def prepare(socket_or_client, opts \\ []) do
    with {:ok, atoms} <- atoms(socket_or_client, opts) do
      SafeRPC.Atoms.prepare(atoms, opts)
    end
  end

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

  def cancel(%SafeRPC.Task{} = request), do: Client.cancel(request)

  def shutdown(%SafeRPC.Task{} = request, _timeout \\ 5_000), do: cancel(request)

  defp ensure_application_loaded(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      _other -> :ok
    end
  end
end
