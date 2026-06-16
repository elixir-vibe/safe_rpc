defmodule SafeRPC.Adapter.Server do
  @moduledoc "SafeRPC server wrapper for framework-agnostic adapter services."

  defmacro __using__(opts) do
    service = Keyword.fetch!(opts, :service)

    quote do
      use SafeRPC.Server

      @impl true
      def init(opts), do: unquote(service).init(opts)

      @impl true
      def handle_call(:safe_rpc_describe, _payload, state) do
        {:reply, SafeRPC.Adapter.Server.describe(unquote(service), state), state}
      end

      def handle_call(op, payload, state) do
        {:reply, unquote(service).call(op, payload, %{}, state), state}
      end

      @impl true
      def handle_request(%{kind: :call, op: :safe_rpc_describe}, state) do
        {:reply, SafeRPC.Adapter.Server.describe(unquote(service), state), state}
      end

      def handle_request(%{kind: :call, op: op, payload: payload, meta: meta}, state) do
        {:reply, unquote(service).call(op, payload, meta, state), state}
      end

      def handle_request(%{kind: :cast, op: op, payload: payload, meta: meta}, state) do
        _result = unquote(service).call(op, payload, meta, state)
        {:reply, {:ok, :noreply}, state}
      end
    end
  end

  def describe(service, state) do
    if function_exported?(service, :__safe_rpc_describe__, 1) do
      {:ok, service.__safe_rpc_describe__(state)}
    else
      {:error, :unsupported}
    end
  end
end
