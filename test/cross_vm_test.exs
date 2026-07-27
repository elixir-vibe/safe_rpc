defmodule SafeRPC.CrossVMTest do
  use ExUnit.Case, async: true

  test "calls a server running in an independent BEAM VM" do
    suffix = System.unique_integer([:positive])
    socket = Path.join(System.tmp_dir!(), "safe-rpc-cross-vm-#{suffix}.sock")
    ready_file = Path.join(System.tmp_dir!(), "safe-rpc-cross-vm-#{suffix}.ready")
    script = Path.expand("fixtures/cross_vm_server", __DIR__)

    args =
      :code.get_path()
      |> Enum.flat_map(fn path -> [~c"-pa", path] end)
      |> Kernel.++([to_charlist(script), to_charlist(socket), to_charlist(ready_file)])

    port =
      Port.open(
        {:spawn_executable, to_charlist(System.find_executable("elixir"))},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
      File.rm(socket)
      File.rm(ready_file)
    end)

    assert wait_until_ready(ready_file, port, 5_000) == :ok

    assert SafeRPC.call(socket, :echo, %{"vm" => "independent"}) ==
             {:ok, %{"vm" => "independent"}}
  end

  defp wait_until_ready(path, port, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until_ready(path, port, deadline, [])
  end

  defp wait_until_ready(path, port, deadline, output) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "cross-VM server did not become ready: #{IO.iodata_to_binary(Enum.reverse(output))}"
        )

      true ->
        receive do
          {^port, {:data, data}} -> wait_until_ready(path, port, deadline, [data | output])
          {^port, {:exit_status, status}} -> flunk("cross-VM server exited with #{status}")
        after
          20 -> wait_until_ready(path, port, deadline, output)
        end
    end
  end
end
