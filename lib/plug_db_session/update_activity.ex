defmodule PlugDbSession.UpdateActivity do
  @moduledoc """
  Plug that forces the session to update at the end of the request, causing the last_active_at timestamp to update.
  """

  @doc false
  def init(default), do: default

  @doc false
  def call(conn, _) do
    Plug.Conn.put_private(conn, :plug_session_info, :write)
  end
end
