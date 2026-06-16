defmodule SafeRPC.Descriptor do
  @moduledoc "Self-description for a SafeRPC service."

  @type t :: %__MODULE__{
          service: atom() | String.t(),
          module: module(),
          version: String.t() | nil,
          surfaces: %{optional(atom() | String.t()) => SafeRPC.Surface.t()},
          meta: map()
        }

  defstruct [:service, :module, :version, surfaces: %{}, meta: %{}]
end
