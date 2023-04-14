defmodule PlugDbSession.Store do
  @moduledoc """
  A custom Plug session store that saves the session to the database.

  Implements `Plug.Session.Store` behaviour.

  ## Options
    * `:otp_app` - (required) your otp app atom
    * `:cookie_keys` - (optional) array of session data keys to include directly on the cookie
  """

  @behaviour Plug.Session.Store

  @impl Plug.Session.Store
  def init(opts) do
    otp_app = Keyword.get(opts, :otp_app)
    config = Application.get_env(otp_app, PlugDbSession, [])

    %{
      cookie_keys: ["session_id" | Keyword.get(opts, :cookie_keys, ["_csrf_token"])],
      vault: Keyword.get(config, :vault),
      repo: Keyword.get(config, :repo),
      schema: Keyword.get(config, :schema),
      encoder: Keyword.get(config, :encoder, PlugDbSession.Encoder)
    }
  end

  @impl Plug.Session.Store
  def get(_conn, cookie, opts) do
    try do
      %{"session_id" => session_id} = decrypt_cookie(cookie, opts)
      session = opts.repo.get(opts.schema, session_id)
      {session.id, decrypt_data(session.data, opts)}
    rescue
      _ ->
        session = create_initial_session(%{}, opts)
        {session.id, %{}}
    end
  end

  # called on first page load with no cookie
  @impl Plug.Session.Store
  def put(_conn, nil = _sid, session_map, opts) do
    session = create_initial_session(session_map, opts)
    create_cookie_from_session(session, opts)
  end

  @impl Plug.Session.Store
  def put(conn, sid, session_data, opts) do
    case opts.repo.get(opts.schema, sid) do
      nil ->
        put(conn, nil, session_data, opts)

      session ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        session
        |> Ecto.Changeset.change(%{data: encrypt_data(session_data, opts), last_active_at: now})
        |> opts.repo.update!()
        |> create_cookie_from_session(opts)
    end
  end

  @impl Plug.Session.Store
  def delete(_conn, sid, opts) do
    session = struct(opts.schema, id: sid)
    opts.repo.delete(session)

    :ok
  end

  defp create_cookie_from_session(session, opts) do
    cookie_keys = Map.get(opts, :cookie_keys, [])

    cookie_extra =
      session.data
      |> decrypt_data(opts)
      |> Map.filter(fn {key, _value} -> Enum.member?(cookie_keys, key) end)

    cookie_required = %{"session_id" => session.id}

    Map.merge(cookie_required, cookie_extra)
    |> encrypt_cookie(opts)
  end

  defp create_initial_session(initial_data, opts) do
    opts.schema |> struct(data: encrypt_data(initial_data, opts)) |> opts.repo.insert!()
  end

  defp encrypt_data(data, opts) do
    data |> opts.encoder.encode!() |> opts.vault.encrypt!()
  end

  defp decrypt_data(bin, opts) do
    bin |> opts.vault.decrypt!() |> opts.encoder.decode!()
  end

  defp encrypt_cookie(data, opts) do
    data |> encrypt_data(opts) |> Base.encode64(padding: false)
  end

  defp decrypt_cookie(str, opts) do
    str |> Base.decode64!(padding: false) |> decrypt_data(opts)
  end
end
