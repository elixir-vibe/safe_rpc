defmodule SafeRPC.Service do
  @moduledoc """
  Elixir-native SafeRPC service DSL.

      defmodule MyApp do
        use SafeRPC, service: :my_app

        @rpc true
        @doc "Return service status."
        @spec status(map(), map(), term()) :: {:ok, map()}
        def status(_payload, _meta, state), do: {:ok, state}
      end

  Only functions marked with `@rpc` are exposed. Operation identity is the
  Elixir module/function pair `{Module, function}`.
  """

  alias SafeRPC.{Descriptor, Op}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour SafeRPC.Adapter.Service
      @safe_rpc_service Keyword.fetch!(opts, :service)
      @safe_rpc_version Keyword.get(opts, :version)
      @safe_rpc_declared_atoms SafeRPC.Atoms.names(Keyword.get(opts, :atoms, []))

      Module.register_attribute(__MODULE__, :rpc, persist: false)
      Module.register_attribute(__MODULE__, :safe_rpc_ops, accumulate: true, persist: true)

      @on_definition SafeRPC.Service
      @before_compile SafeRPC.Service

      @impl SafeRPC.Adapter.Service
      def init(opts), do: {:ok, opts}

      defoverridable init: 1
    end
  end

  def __on_definition__(env, kind, name, args, _guards, _body)
      when kind in [:def, :defp] do
    case Module.get_attribute(env.module, :rpc) do
      nil ->
        :ok

      false ->
        Module.delete_attribute(env.module, :rpc)

      rpc_opts ->
        register_rpc!(
          env.module,
          kind,
          name,
          length(args),
          rpc_opts,
          Module.get_attribute(env.module, :doc),
          Module.get_attribute(env.module, :spec)
        )

        Module.delete_attribute(env.module, :rpc)
    end
  end

  defmacro __before_compile__(env) do
    ops =
      env.module
      |> Module.get_attribute(:safe_rpc_ops)
      |> Enum.reverse()

    call_clauses =
      Enum.map(ops, fn %{module: module, function: function, arity: arity} ->
        call_clause(module, function, arity)
      end)

    quote do
      @doc false
      def __safe_rpc_ops__, do: unquote(Macro.escape(ops))

      @doc false
      def __safe_rpc_atoms__,
        do: SafeRPC.Service.atoms(@safe_rpc_declared_atoms, @safe_rpc_service, __safe_rpc_ops__())

      @doc false
      def __safe_rpc_descriptor__ do
        SafeRPC.Service.descriptor(
          __MODULE__,
          @safe_rpc_service,
          @safe_rpc_version,
          __safe_rpc_ops__()
        )
      end

      @impl SafeRPC.Adapter.Service
      def call(op, payload, meta, state)
      unquote_splicing(call_clauses)
      def call(_op, _payload, _meta, _state), do: {:error, :unknown_operation}

      @doc false
      @impl SafeRPC.Adapter.Service
      def __safe_rpc_describe__(_state), do: __safe_rpc_descriptor__()
    end
  end

  def atoms(declared_atoms, service, ops) do
    op_atoms = Enum.flat_map(ops, &[&1.module, &1.function])

    spec_atoms =
      ops
      |> Enum.flat_map(&Map.get(&1, :atoms, []))
      |> Enum.filter(&vocabulary_atom?/1)

    SafeRPC.Atoms.names([declared_atoms, service, op_atoms, spec_atoms])
  end

  def descriptor(module, service, version, ops) do
    docs = docs_by_function(module)
    specs = specs_by_function(module)

    module_description = %{
      ops:
        ops
        |> Enum.map(&op(module, &1, docs, specs))
        |> Map.new(&{&1.name, &1}),
      meta: %{}
    }

    %Descriptor{
      service: service,
      module: module,
      version: version,
      modules: %{module => module_description}
    }
  end

  defp register_rpc!(module, :defp, name, _arity, _rpc_opts, _doc, _spec) do
    raise ArgumentError,
          "private function #{inspect(module)}.#{name}/3 cannot be exposed with @rpc"
  end

  defp register_rpc!(module, :def, name, arity, rpc_opts, doc, spec) do
    if arity != 3 do
      raise ArgumentError,
            "@rpc function #{inspect(module)}.#{name}/#{arity} must have arity 3: payload, meta, state"
    end

    opts = normalize_rpc_opts(rpc_opts)
    meta = Map.new(opts)

    Module.put_attribute(module, :safe_rpc_ops, %{
      module: module,
      function: name,
      arity: arity,
      docs: doc_string(doc),
      spec: spec_string(spec),
      atoms: atoms_from_spec(spec),
      meta: meta
    })
  end

  defp normalize_rpc_opts(true), do: []
  defp normalize_rpc_opts(opts) when is_list(opts), do: opts

  defp normalize_rpc_opts(other) do
    raise ArgumentError, "@rpc expects true or keyword options, got: #{inspect(other)}"
  end

  defp call_clause(module, function, 3) do
    quote do
      def call({unquote(module), unquote(function)}, payload, meta, state),
        do: unquote(function)(payload, meta, state)
    end
  end

  defp op(module, attrs, docs, specs) do
    key = {attrs.function, attrs.arity}

    %Op{
      name: attrs.function,
      module: attrs.module || module,
      function: attrs.function,
      arity: attrs.arity,
      docs: attrs.docs || Map.get(docs, key),
      spec: attrs.spec || spec_string(Map.get(specs, key)),
      meta: attrs.meta
    }
  end

  defp docs_by_function(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _beam, _format, _module_doc, _metadata, docs} ->
        docs
        |> Enum.flat_map(fn
          {{:function, name, arity}, _anno, _signature, doc, _metadata} ->
            [{{name, arity}, doc_string(doc)}]

          _other ->
            []
        end)
        |> Map.new()

      _other ->
        %{}
    end
  end

  defp vocabulary_atom?(atom) when is_atom(atom) do
    name = Atom.to_string(atom)
    String.match?(name, ~r/^(Elixir\.)?[A-Za-z][A-Za-z0-9_.]*[?!]?$/)
  end

  defp atoms_from_spec(nil), do: []

  defp atoms_from_spec(specs) when is_list(specs) do
    Enum.flat_map(specs, fn
      {:spec, spec, _location} -> collect_atoms(spec, [])
      spec -> collect_atoms(spec, [])
    end)
  end

  defp atoms_from_spec(spec), do: collect_atoms(spec, [])

  defp collect_atoms(atom, atoms) when is_atom(atom), do: [atom | atoms]

  defp collect_atoms({name, meta, args}, atoms)
       when is_atom(name) and is_list(meta) and is_list(args) do
    collect_atoms(args, atoms)
  end

  defp collect_atoms(tuple, atoms) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> collect_atoms(atoms)
  end

  defp collect_atoms(list, atoms) when is_list(list) do
    Enum.reduce(list, atoms, &collect_atoms/2)
  end

  defp collect_atoms(_other, atoms), do: atoms

  defp spec_string(nil), do: nil
  defp spec_string(spec), do: inspect(spec, limit: :infinity, printable_limit: :infinity)

  defp doc_string({_line, doc}), do: doc_string(doc)
  defp doc_string(%{"en" => doc}) when is_binary(doc), do: doc
  defp doc_string(doc) when is_binary(doc), do: doc
  defp doc_string(:none), do: nil
  defp doc_string(:hidden), do: nil
  defp doc_string(_other), do: nil

  defp specs_by_function(module) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} -> Map.new(specs, fn {{name, arity}, spec} -> {{name, arity}, spec} end)
      :error -> %{}
    end
  end
end
