defmodule PlugDbSession.Store do
  def init(opts) do
    otp_app = Keyword.get(opts, :otp_app)
    config = Application.get_env(otp_app, PlugDbSession, [])

    %{
      include_in_cookie: [:_csrf_token, :session_id | Keyword.get(opts, :include_in_cookie, [])],
      vault: Keyword.get(config, :vault),
      repo: Keyword.get(config, :repo),
      schema: Keyword.get(config, :schema, PlugDbSession.Session),
      json: Keyword.get(config, :json)
    }
  end

  def get(_conn, cookie, opts) do
    cookie_data = decrypt_cookie(cookie, opts)

    case cookie_data do
      %{"session_id" => session_id} ->
        session = opts.repo.get(opts.schema, session_id)

        {session_id, decrypt_data(session.data, opts)}

      _ ->
        session = create_initial_session(%{}, opts)

        {session.id, %{}}
    end
  end

  # called on first page load with no cookie
  def put(_conn, nil = _sid, session_map, opts) do
    session = opts.schema |> struct(data: encrypt_data(session_map, opts)) |> opts.repo.insert!()

    create_cookie_from_session(session, opts)
  end

  def put(conn, sid, session_data, opts) do
    session = opts.repo.get(opts.schema, sid)

    case session do
      nil ->
        put(conn, nil, session_data, opts)

      _ ->
        session =
          session
          |> Ecto.Changeset.change(%{data: encrypt_data(session_data, opts)})
          |> opts.repo.update!()

        create_cookie_from_session(session, opts)
    end
  end

  def delete(_conn, sid, opts) do
    session = struct(opts.schema, id: sid)

    opts.repo.delete(session)

    :ok
  end

  defp create_cookie_from_session(session, opts) do
    data = decrypt_data(session.data, opts)

    %{session_id: session.id, _csrf_token: data["_csrf_token"]}
    |> encrypt_cookie(opts)
  end

  defp create_initial_session(initial_data, opts) do
    opts.schema |> struct(data: encrypt_data(initial_data, opts)) |> opts.repo.insert!()
  end

  defp encrypt_data(data, opts) do
    data |> opts.json.encode!() |> opts.vault.encrypt!()
  end

  defp decrypt_data(bin, opts) do
    bin |> opts.vault.decrypt!() |> opts.json.decode!()
  end

  defp encrypt_cookie(data, opts) do
    data |> encrypt_data(opts) |> Base.encode64()
  end

  defp decrypt_cookie(str, opts) do
    str |> Base.decode64!() |> decrypt_data(opts)
  end
end
