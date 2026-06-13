defmodule SafeRPC.Task do
  @moduledoc "A SafeRPC asynchronous request."

  defstruct [:client, :id, :op]
end
