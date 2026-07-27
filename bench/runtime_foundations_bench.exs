Code.require_file("support/config.exs", __DIR__)

defmodule SafeRPCBench.RuntimeServer do
  use SafeRPC.Server

  def init(_opts), do: {:ok, %{}}
  def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}

  def handle_call(:work, %{delay_ms: delay_ms}, state) do
    Process.sleep(delay_ms)
    {:reply, {:ok, :done}, state}
  end
end

defmodule SafeRPCBench.TelemetryHandler do
  def handle(_event, _measurements, _metadata, _config), do: :ok
end

defmodule SafeRPCBench.Runtime do
  alias SafeRPCBench.Config

  def run do
    suffix = System.unique_integer([:positive])
    serial_socket = Path.join(System.tmp_dir!(), "safe-rpc-bench-serial-#{suffix}.sock")
    concurrent_socket = Path.join(System.tmp_dir!(), "safe-rpc-bench-concurrent-#{suffix}.sock")

    {:ok, serial_server} =
      SafeRPCBench.RuntimeServer.start_link(socket: serial_socket, execution: :serial)

    {:ok, concurrent_server} =
      SafeRPCBench.RuntimeServer.start_link(
        socket: concurrent_socket,
        execution: :concurrent,
        max_in_flight: 512,
        max_in_flight_per_connection: 256
      )

    {:ok, serial_client} = SafeRPC.Client.start_link(socket: serial_socket)
    {:ok, concurrent_client} = SafeRPC.Client.start_link(socket: concurrent_socket)

    delay_ms = Config.integer("SAFERPC_BENCH_DELAY_MS", 5)

    for parallel <-
          Config.list("SAFERPC_BENCH_PARALLEL", "1,4,16,64") |> Enum.map(&String.to_integer/1) do
      Benchee.run(
        %{
          "serial" => fn ->
            SafeRPC.call(serial_client, :work, %{delay_ms: delay_ms}, timeout: 30_000)
          end,
          "concurrent" => fn ->
            SafeRPC.call(concurrent_client, :work, %{delay_ms: delay_ms}, timeout: 30_000)
          end
        },
        Config.options("runtime-work-p#{parallel}", parallel)
      )
    end

    if System.get_env("SAFERPC_BENCH_TELEMETRY", "true") == "true" do
      compare_telemetry(concurrent_client)
    end

    GenServer.stop(concurrent_client)
    GenServer.stop(serial_client)
    GenServer.stop(concurrent_server)
    GenServer.stop(serial_server)
  end

  defp compare_telemetry(client) do
    suffix = System.unique_integer([:positive])
    baseline_path = Path.join(System.tmp_dir!(), "safe-rpc-telemetry-off-#{suffix}.benchee")
    enabled_path = Path.join(System.tmp_dir!(), "safe-rpc-telemetry-on-#{suffix}.benchee")
    scenario = %{"echo" => fn -> SafeRPC.call(client, :echo, :payload) end}

    common = [
      warmup: Config.integer("SAFERPC_BENCH_WARMUP", 1),
      time: Config.integer("SAFERPC_BENCH_TIME", 3),
      memory_time: Config.integer("SAFERPC_BENCH_MEMORY_TIME", 1),
      parallel: 1,
      print: [fast_warning: false]
    ]

    Benchee.run(scenario, common ++ [save: [path: baseline_path, tag: "telemetry off"]])

    handler_id = "safe-rpc-benchmark-#{suffix}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:safe_rpc, :request, :start],
          [:safe_rpc, :request, :stop],
          [:safe_rpc, :request, :exception]
        ],
        &SafeRPCBench.TelemetryHandler.handle/4,
        nil
      )

    Benchee.run(
      scenario,
      common ++
        [
          load: baseline_path,
          save: [path: enabled_path, tag: "telemetry on"]
        ]
    )

    :telemetry.detach(handler_id)
    File.rm(baseline_path)
    File.rm(enabled_path)
  end
end

SafeRPCBench.Runtime.run()
