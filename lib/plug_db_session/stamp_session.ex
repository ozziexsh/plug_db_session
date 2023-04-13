defmodule PlugDbSession.StampSession do
  def init(default), do: default

  def call(conn, _) do
    Plug.Conn.put_private(conn, :plug_session_info, :write)
  end
end
