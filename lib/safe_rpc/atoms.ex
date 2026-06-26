defmodule SafeRPC.Atoms do
  @moduledoc """
  Bounded atom vocabulary preparation for SafeRPC clients.

  SafeRPC decodes protocol frames with `:safe`, so replies can only contain atoms
  that already exist in the client VM. A service may expose a bounded vocabulary
  as strings; clients validate that vocabulary and intentionally intern accepted
  atoms before making calls that may return them.
  """

  @type policy :: [
          max_atoms: pos_integer(),
          max_atom_length: pos_integer(),
          allow: [Regex.t() | (String.t() -> as_boolean(term()))]
        ]

  @default_max_atoms 1_000
  @default_max_atom_length 128

  @doc "Validates and interns an atom vocabulary."
  @spec prepare([String.t()], policy()) :: :ok | {:error, term()}
  def prepare(names, opts \\ [])

  def prepare(names, opts) when is_list(names) do
    with :ok <- validate_count(names, opts),
         :ok <- validate_names(names, opts) do
      Enum.each(names, &String.to_atom/1)
      :ok
    end
  end

  def prepare(other, _opts), do: {:error, {:invalid_atom_vocabulary, other}}

  @doc "Normalizes atoms and module names to unique strings."
  @spec names([atom() | module() | String.t()]) :: [String.t()]
  def names(values) when is_list(values) do
    values
    |> List.flatten()
    |> Enum.map(&name!/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp name!(value) when is_atom(value), do: Atom.to_string(value)
  defp name!(value) when is_binary(value), do: value

  defp validate_count(names, opts) do
    max = Keyword.get(opts, :max_atoms, @default_max_atoms)

    if length(names) <= max do
      :ok
    else
      {:error, {:too_many_atoms, length(names), max}}
    end
  end

  defp validate_names(names, opts) do
    max_length = Keyword.get(opts, :max_atom_length, @default_max_atom_length)
    allow = Keyword.get(opts, :allow, [])

    Enum.reduce_while(names, :ok, fn name, :ok ->
      cond do
        not is_binary(name) ->
          {:halt, {:error, {:invalid_atom_name, name}}}

        byte_size(name) > max_length ->
          {:halt, {:error, {:atom_name_too_long, name, max_length}}}

        allow != [] and not allowed?(name, allow) ->
          {:halt, {:error, {:atom_not_allowed, name}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp allowed?(name, allow) do
    Enum.any?(allow, fn
      %Regex{} = regex -> Regex.match?(regex, name)
      fun when is_function(fun, 1) -> fun.(name)
    end)
  end
end
