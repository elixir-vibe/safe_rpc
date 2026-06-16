defmodule SafeRPC.Op do
  @moduledoc "A SafeRPC operation exposed by an Elixir function."

  @type t :: %__MODULE__{
          name: atom(),
          surface: atom() | String.t(),
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          docs: String.t() | nil,
          spec: term(),
          meta: map()
        }

  defstruct [
    :name,
    :surface,
    :module,
    :function,
    :arity,
    :docs,
    :spec,
    meta: %{}
  ]
end
