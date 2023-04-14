defmodule PlugDbSession.MixProject do
  use Mix.Project

  def project do
    [
      app: :plug_db_session,
      name: "PlugDbSession",
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      docs: [
        main: "readme",
        extras: ["README.md"]
      ],
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Plug database session driver"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ozziexsh/plug_db_session"}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.29.4", only: :dev, runtime: false},
      {:ecto, "~> 3.10"},
      {:plug, "~> 1.14"}
    ]
  end
end
