defmodule SafeRPC.Protocol do
  @moduledoc "Term protocol encoding for SafeRPC."

  @version 1

  def encode_call(id, cap, op, payload),
    do: encode({:safe_rpc, @version, id, cap, :call, op, payload})

  def encode_cast(id, cap, op, payload),
    do: encode({:safe_rpc, @version, id, cap, :cast, op, payload})

  def encode_reply(id, result), do: encode({:safe_rpc_reply, @version, id, result})

  def decode_request(binary) do
    case decode(binary) do
      {:safe_rpc, @version, id, cap, kind, op, payload} when kind in [:call, :cast] ->
        {:ok, %{id: id, cap: cap, kind: kind, op: op, payload: payload}}

      other ->
        {:error, {:invalid_request, other}}
    end
  end

  def decode_reply(binary, id) do
    case decode(binary) do
      {:safe_rpc_reply, @version, ^id, result} -> {:ok, result}
      other -> {:error, {:invalid_reply, other}}
    end
  end

  defp encode(term), do: :erlang.term_to_binary(term)
  defp decode(binary), do: :erlang.binary_to_term(binary, [:safe])
end
