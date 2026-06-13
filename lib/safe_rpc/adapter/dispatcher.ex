defmodule SafeRPC.Adapter.Dispatcher do
  @moduledoc "Dispatches SafeRPC operations to explicit MFA route tables."

  @type route :: {module(), atom(), 3} | {module(), atom(), 4}

  @spec call(%{optional(atom()) => route()}, atom(), term(), map(), term()) :: term()
  def call(routes, op, payload, meta, state) when is_map(routes) do
    case Map.fetch(routes, op) do
      {:ok, {module, function, 3}} -> apply(module, function, [payload, meta, state])
      {:ok, {module, function, 4}} -> apply(module, function, [op, payload, meta, state])
      :error -> {:error, :unknown_operation}
    end
  end
end
