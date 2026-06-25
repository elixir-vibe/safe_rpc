defmodule SafeRPC.MixProject do
  use Mix.Project

  @version "0.1.8"
  @source_url "https://github.com/elixir-vibe/safe_rpc"

  def project do
    [
      app: :safe_rpc,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: description(),
      source_url: @source_url,
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger]
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]

  defp description do
    "Capability-scoped RPC over safe Erlang external term format."
  end

  defp deps do
    [
      {:plug, "~> 1.18"},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp aliases do
    [
      ci: [
        "format",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test"
      ]
    ]
  end
end
