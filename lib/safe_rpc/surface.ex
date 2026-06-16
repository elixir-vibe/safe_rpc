defmodule SafeRPC.Surface do
  @moduledoc "A broad SafeRPC surface containing operation descriptions."

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          ops: %{optional(atom()) => SafeRPC.Op.t()},
          meta: map()
        }

  defstruct [:name, ops: %{}, meta: %{}]
end
