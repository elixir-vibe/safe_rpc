defmodule SafeRPC.Protocol do
  @moduledoc "Term protocol encoding for SafeRPC."

  @version 1

  def encode_call(id, cap, op, payload, meta \\ %{}),
    do: encode({:safe_rpc, @version, id, cap, :call, op, payload, meta})

  def encode_cast(id, cap, op, payload, meta \\ %{}),
    do: encode({:safe_rpc, @version, id, cap, :cast, op, payload, meta})

  def encode_cancel(id), do: encode({:safe_rpc_cancel, @version, id})

  def encode_reply(id, result), do: encode({:safe_rpc_reply, @version, id, result})

  def decode_request(binary) when is_binary(binary) do
    with {:ok, term} <- decode(binary) do
      case term do
        {:safe_rpc, @version, id, cap, kind, op, payload, meta} when kind in [:call, :cast] ->
          {:ok, %{id: id, cap: cap, kind: kind, op: op, payload: payload, meta: meta}}

        {:safe_rpc_cancel, @version, id} ->
          {:ok, %{id: id, kind: :cancel}}

        other ->
          {:error, {:invalid_request, other}}
      end
    end
  end

  def decode_reply(binary) when is_binary(binary) do
    with {:ok, term} <- decode(binary) do
      case term do
        {:safe_rpc_reply, @version, id, result} -> {:ok, %{id: id, result: result}}
        other -> {:error, {:invalid_reply, other}}
      end
    end
  end

  def decode_reply(binary, id) when is_binary(binary) do
    with {:ok, reply} <- decode_reply(binary) do
      case reply do
        %{id: ^id, result: result} -> {:ok, result}
        other -> {:error, {:invalid_reply, other}}
      end
    end
  end

  defp encode(term), do: :erlang.term_to_binary(term)

  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    error in [ArgumentError] -> {:error, {:invalid_term, error}}
  end
end
