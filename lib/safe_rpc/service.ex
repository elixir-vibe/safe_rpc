defmodule SafeRPC.Service do
  @moduledoc """
  Elixir-native SafeRPC service DSL.

      defmodule MyApp do
        use SafeRPC, service: :my_app, surface: :api

        @rpc true
        @doc "Return service status."
        @spec status(map(), map(), term()) :: {:ok, map()}
        def status(_payload, _meta, state), do: {:ok, state}
      end

  Only functions marked with `@rpc` are exposed. Function names are operation
  names by default. The module-level `:surface` option is the default surface;
  use `@rpc surface: :control` to override it for one function.
  """

  alias SafeRPC.{Descriptor, Op, Surface}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour SafeRPC.Adapter.Service
      @safe_rpc_service Keyword.fetch!(opts, :service)
      @safe_rpc_version Keyword.get(opts, :version)
      @safe_rpc_default_surface Keyword.get(opts, :surface, :default)

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
      Enum.map(ops, fn %{op: op, function: function, arity: arity} ->
        call_clause(op, function, arity)
      end)

    quote do
      @doc false
      def __safe_rpc_ops__, do: unquote(Macro.escape(ops))

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

  def descriptor(module, service, version, ops) do
    docs = docs_by_function(module)
    specs = specs_by_function(module)

    surfaces =
      ops
      |> Enum.map(&op(module, &1, docs, specs))
      |> Enum.group_by(& &1.surface)
      |> Map.new(fn {surface, ops} ->
        {surface, %Surface{name: surface, ops: Map.new(ops, &{&1.name, &1})}}
      end)

    %Descriptor{service: service, module: module, version: version, surfaces: surfaces}
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
    surface = Keyword.get(opts, :surface, Module.get_attribute(module, :safe_rpc_default_surface))
    meta = opts |> Keyword.drop([:surface]) |> Map.new()

    Module.put_attribute(module, :safe_rpc_ops, %{
      op: name,
      surface: surface,
      function: name,
      arity: arity,
      docs: doc_string(doc),
      spec: spec,
      meta: meta
    })
  end

  defp normalize_rpc_opts(true), do: []
  defp normalize_rpc_opts(opts) when is_list(opts), do: opts

  defp normalize_rpc_opts(other) do
    raise ArgumentError, "@rpc expects true or keyword options, got: #{inspect(other)}"
  end

  defp call_clause(op, function, 3) do
    quote do
      def call(unquote(op), payload, meta, state),
        do: unquote(function)(payload, meta, state)
    end
  end

  defp op(module, attrs, docs, specs) do
    key = {attrs.function, attrs.arity}

    %Op{
      name: attrs.op,
      surface: attrs.surface,
      module: module,
      function: attrs.function,
      arity: attrs.arity,
      docs: attrs.docs || Map.get(docs, key),
      spec: attrs.spec || Map.get(specs, key),
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
