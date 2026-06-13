defmodule SafeRPC.Capability do
  @moduledoc "Capability checks for SafeRPC operations."

  defstruct token: nil, ops: :all

  def new(opts), do: struct!(__MODULE__, Map.new(opts))

  def allowed?(_capability, nil, _op), do: false

  def allowed?(%__MODULE__{token: token, ops: :all}, candidate, _op),
    do: same_token?(token, candidate)

  def allowed?(%__MODULE__{token: token, ops: ops}, candidate, op) when is_list(ops),
    do: same_token?(token, candidate) and op in ops

  def allowed?(_capability, _token, _op), do: false

  defp same_token?(token, candidate) when is_binary(token) and is_binary(candidate) do
    byte_size(token) == byte_size(candidate) and :crypto.hash_equals(token, candidate)
  end

  defp same_token?(token, candidate), do: token == candidate
end
