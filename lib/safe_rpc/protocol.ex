defmodule SafeRPC.Protocol do
  @moduledoc "Term protocol encoding for SafeRPC."

  @version 1
  @default_max_frame_size 16 * 1024 * 1024

  @type request_id :: non_neg_integer()

  defguardp is_operation(op)
            when is_atom(op) or
                   (is_tuple(op) and tuple_size(op) == 2 and is_atom(elem(op, 0)) and
                      is_atom(elem(op, 1)))

  @doc "The default maximum encoded frame size in bytes."
  @spec default_max_frame_size() :: pos_integer()
  def default_max_frame_size, do: @default_max_frame_size

  @spec encode_call(request_id(), term(), term(), term(), map()) :: binary()
  def encode_call(id, cap, op, payload, meta \\ %{}),
    do: encode({:safe_rpc, @version, id, cap, :call, op, payload, meta})

  @spec encode_cast(request_id(), term(), term(), term(), map()) :: binary()
  def encode_cast(id, cap, op, payload, meta \\ %{}),
    do: encode({:safe_rpc, @version, id, cap, :cast, op, payload, meta})

  @spec encode_cancel(request_id()) :: binary()
  def encode_cancel(id), do: encode({:safe_rpc_cancel, @version, id})

  @spec encode_reply(request_id(), term()) :: binary()
  def encode_reply(id, result), do: encode({:safe_rpc_reply, @version, id, result})

  @doc "Rejects an encoded frame larger than the configured limit."
  @spec validate_frame_size(binary(), pos_integer()) :: :ok | {:error, term()}
  def validate_frame_size(binary, max_size \\ @default_max_frame_size)
      when is_binary(binary) and is_integer(max_size) and max_size > 0 do
    size = byte_size(binary)

    if size <= max_size do
      :ok
    else
      {:error, {:frame_too_large, size, max_size}}
    end
  end

  @spec decode_request(binary()) :: {:ok, map()} | {:error, term()}
  def decode_request(binary) when is_binary(binary) do
    with {:ok, term} <- decode(binary) do
      case term do
        {:safe_rpc, @version, id, cap, kind, op, payload, meta}
        when is_integer(id) and id >= 0 and kind in [:call, :cast] and is_operation(op) and
               is_map(meta) ->
          {:ok, %{id: id, cap: cap, kind: kind, op: op, payload: payload, meta: meta}}

        {:safe_rpc_cancel, @version, id} when is_integer(id) and id >= 0 ->
          {:ok, %{id: id, kind: :cancel}}

        other ->
          {:error, {:invalid_request, other}}
      end
    end
  end

  @spec decode_reply(binary()) :: {:ok, map()} | {:error, term()}
  def decode_reply(binary) when is_binary(binary) do
    with {:ok, term} <- decode(binary) do
      case term do
        {:safe_rpc_reply, @version, id, result} when is_integer(id) and id >= 0 ->
          {:ok, %{id: id, result: result}}

        other ->
          {:error, {:invalid_reply, other}}
      end
    end
  end

  @spec decode_reply(binary(), request_id()) :: {:ok, term()} | {:error, term()}
  def decode_reply(binary, id) when is_binary(binary) do
    with {:ok, reply} <- decode_reply(binary) do
      case reply do
        %{id: ^id, result: result} -> {:ok, result}
        other -> {:error, {:invalid_reply, other}}
      end
    end
  end

  defp encode(term), do: :erlang.term_to_binary(term)

  defp decode(<<131, 80, _compressed::binary>>),
    do: {:error, :compressed_terms_not_supported}

  defp decode(binary) do
    {:ok, Plug.Crypto.non_executable_binary_to_term(binary, [:safe])}
  rescue
    error in [ArgumentError] -> {:error, {:invalid_term, error}}
  end
end
