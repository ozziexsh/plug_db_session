defmodule PlugDbSession.Session do
  use Ecto.Schema

  schema "sessions" do
    field(:data, :binary)
    field(:last_active_at, :utc_datetime)
    field(:created_at, :utc_datetime)
  end
end
