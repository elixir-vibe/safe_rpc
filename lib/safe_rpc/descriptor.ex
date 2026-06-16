defmodule SafeRPC.Descriptor do
  @moduledoc "Self-description for a SafeRPC service."

  @type module_description :: %{
          ops: %{optional(atom()) => SafeRPC.Op.t()},
          meta: map()
        }

  @type t :: %__MODULE__{
          service: atom() | String.t(),
          module: module(),
          version: String.t() | nil,
          modules: %{optional(module()) => module_description()},
          meta: map()
        }

  defstruct [:service, :module, :version, modules: %{}, meta: %{}]
end
