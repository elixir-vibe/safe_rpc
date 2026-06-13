defmodule SafeRPC.Protocol do
  @moduledoc "Term protocol encoding for SafeRPC."

  @version 1

  def encode_call(id, cap, op, payload),
    do: encode({:safe_rpc, @version, id, cap, :call, op, payload})

  def encode_cast(id, cap, op, payload),
    do: encode({:safe_rpc, @version, id, cap, :cast, op, payload})

  def encode_reply(id, result), do: encode({:safe_rpc_reply, @version, id, result})

  def decode_request(binary) when is_binary(binary) do
    with {:ok, term} <- decode(binary) do
      case term do
        {:safe_rpc, @version, id, cap, kind, op, payload} when kind in [:call, :cast] ->
          {:ok, %{id: id, cap: cap, kind: kind, op: op, payload: payload}}

        other ->
          {:error, {:invalid_request, other}}
      end
    end
  end

  def decode_reply(binary, id) when is_binary(binary) do
    with {:ok, term} <- decode(binary) do
      case term do
        {:safe_rpc_reply, @version, ^id, result} -> {:ok, result}
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
