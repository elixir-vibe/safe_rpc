defmodule SafeRPC.Op do
  @moduledoc "A SafeRPC operation exposed by an Elixir function."

  @type t :: %__MODULE__{
          name: atom(),
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          docs: String.t() | nil,
          spec: String.t() | nil,
          meta: map()
        }

  defstruct [
    :name,
    :module,
    :function,
    :arity,
    :docs,
    :spec,
    meta: %{}
  ]
end
