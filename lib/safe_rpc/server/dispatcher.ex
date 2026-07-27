defmodule SafeRPC.Server.Dispatcher do
  @moduledoc false

  require Logger

  alias SafeRPC.Capability

  @event_prefix [:safe_rpc, :request]

  def dispatch(request, config) do
    started_at = System.monotonic_time()
    metadata = %{execution: config.execution, kind: request.kind, operation: request.op}

    :telemetry.execute(@event_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      {reply, user_state} =
        request
        |> authorize_and_invoke(config)
        |> enforce_execution_mode(config)

      :telemetry.execute(
        @event_prefix ++ [:stop],
        %{duration: System.monotonic_time() - started_at},
        Map.put(metadata, :outcome, outcome(reply))
      )

      {reply, user_state}
    catch
      kind, reason ->
        :telemetry.execute(
          @event_prefix ++ [:exception],
          %{duration: System.monotonic_time() - started_at},
          Map.merge(metadata, %{exception_kind: kind, error: error_class(reason)})
        )

        Logger.error(fn ->
          banner = Exception.format_banner(kind, reason, __STACKTRACE__)
          "SafeRPC request failed op=#{inspect(request.op)}: #{banner}"
        end)

        {{:error, :internal}, config.user_state}
    end
  end

  defp authorize_and_invoke(request, config) do
    with :ok <- authorize_capability(request, config.capability),
         :ok <- config.authorizer.authorize(request, config.auth_context) do
      case config.handler.handle_request(request, config.user_state) do
        {:reply, reply, user_state} -> {reply, user_state}
      end
    else
      {:error, reason} -> {{:error, reason}, config.user_state}
    end
  end

  defp enforce_execution_mode({reply, user_state}, %{execution: :serial}),
    do: {reply, user_state}

  defp enforce_execution_mode({reply, user_state}, %{execution: :concurrent} = config) do
    if user_state === config.user_state do
      {reply, user_state}
    else
      {{:error, :stateful_handler_requires_serial_execution}, config.user_state}
    end
  end

  defp authorize_capability(_request, nil), do: :ok

  defp authorize_capability(request, capability) do
    if Capability.allowed?(capability, request.cap, request.op) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp outcome({:error, _reason}), do: :error
  defp outcome(_reply), do: :ok

  defp error_class(%{__struct__: module}) when is_atom(module), do: module
  defp error_class(_reason), do: :non_exception
end
