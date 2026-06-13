defmodule SafeRPC.Capability do
  @moduledoc "Capability checks for SafeRPC operations."

  defstruct token: nil, ops: :all

  def new(opts), do: struct!(__MODULE__, Map.new(opts))

  def allowed?(_capability, nil, _op), do: false
  def allowed?(%__MODULE__{token: token, ops: :all}, token, _op), do: true
  def allowed?(%__MODULE__{token: token, ops: ops}, token, op), do: op in ops
  def allowed?(_capability, _token, _op), do: false
end
