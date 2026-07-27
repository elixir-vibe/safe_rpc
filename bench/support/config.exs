defmodule SafeRPCBench.Config do
  def integer(name, default) do
    name
    |> System.get_env(Integer.to_string(default))
    |> String.to_integer()
  end

  def list(name, default) do
    name
    |> System.get_env(default)
    |> String.split(",", trim: true)
  end

  def options(name, parallel) do
    [
      warmup: integer("SAFERPC_BENCH_WARMUP", 1),
      time: integer("SAFERPC_BENCH_TIME", 3),
      memory_time: integer("SAFERPC_BENCH_MEMORY_TIME", 1),
      parallel: parallel,
      print: [fast_warning: false],
      save: save_options(name),
      load: load_path(name)
    ]
    |> Enum.reject(fn {_key, value} -> value == false end)
  end

  defp save_options(name) do
    case System.get_env("SAFERPC_BENCH_SAVE_DIR") do
      nil ->
        false

      directory ->
        File.mkdir_p!(directory)

        [
          path: Path.join(directory, name <> ".benchee"),
          tag: System.get_env("SAFERPC_BENCH_TAG", "current")
        ]
    end
  end

  defp load_path(name) do
    case System.get_env("SAFERPC_BENCH_LOAD_DIR") do
      nil ->
        false

      directory ->
        path = Path.join(directory, name <> ".benchee")
        if File.exists?(path), do: path, else: false
    end
  end
end
