ExUnit.start()

unless System.get_env("SAFERPC_INTEGRATION") == "1" do
  ExUnit.configure(exclude: [integration: true])
end

unless System.get_env("SAFERPC_STRESS") == "1" do
  ExUnit.configure(exclude: [stress: true])
end
