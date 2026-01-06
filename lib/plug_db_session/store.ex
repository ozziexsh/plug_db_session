defmodule PlugDbSession.Store do
  @moduledoc """
  A custom Plug session store that saves the session to the database.

  Implements `Plug.Session.Store` behaviour.

  ## Security

  This store uses a hash-based session ID scheme to prevent timing attacks:
  - A random token is generated and sent to the client in an encrypted cookie
  - The SHA-256 hash of the token is stored as the database primary key
  - On lookup, the token is hashed before querying the database

  This ensures that even if encryption is bypassed, timing attacks on database
  lookups cannot reveal valid session tokens.

  ## Options
    * `:otp_app` - (required) your otp app atom
    * `:cookie_keys` - (optional) array of session data keys to include directly on the cookie
  """

  @behaviour Plug.Session.Store

  @token_bytes 32

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
    with {:ok, %{"session_id" => token}} <- decrypt_cookie(cookie, opts),
         hashed_id <- hash_token(token),
         %{} = session <- opts.repo.get(opts.schema, hashed_id) do
      {token, decrypt_data(session.data, opts)}
    else
      _ ->
        {token, _session} = create_initial_session(%{}, opts)
        {token, %{}}
    end
  end

  # called on first page load with no cookie
  @impl Plug.Session.Store
  def put(_conn, nil = _sid, session_map, opts) do
    {token, _session} = create_initial_session(session_map, opts)
    create_cookie(token, session_map, opts)
  end

  @impl Plug.Session.Store
  def put(conn, token, session_data, opts) do
    hashed_id = hash_token(token)

    case opts.repo.get(opts.schema, hashed_id) do
      nil ->
        put(conn, nil, session_data, opts)

      session ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        session
        |> Ecto.Changeset.change(%{data: encrypt_data(session_data, opts), last_active_at: now})
        |> opts.repo.update!()

        create_cookie(token, session_data, opts)
    end
  end

  @impl Plug.Session.Store
  def delete(_conn, token, opts) do
    hashed_id = hash_token(token)
    session = struct(opts.schema, id: hashed_id)
    opts.repo.delete(session)

    :ok
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token)
  end

  defp create_cookie(token, session_data, opts) do
    cookie_keys = Map.get(opts, :cookie_keys, [])

    cookie_extra =
      session_data
      |> Map.filter(fn {key, _value} -> Enum.member?(cookie_keys, key) end)

    cookie_required = %{"session_id" => token}

    Map.merge(cookie_required, cookie_extra)
    |> encrypt_cookie(opts)
  end

  defp create_initial_session(initial_data, opts) do
    token = generate_token()
    hashed_id = hash_token(token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    session =
      opts.schema
      |> struct(%{
        id: hashed_id,
        data: encrypt_data(initial_data, opts),
        last_active_at: now,
        created_at: now
      })
      |> opts.repo.insert!()

    {token, session}
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

  defp decrypt_cookie(nil, _opts), do: :error

  defp decrypt_cookie(str, opts) do
    with {:ok, bin} <- Base.decode64(str, padding: false),
         {:ok, decrypted} <- safe_decrypt(bin, opts) do
      {:ok, opts.encoder.decode!(decrypted)}
    end
  end

  defp safe_decrypt(bin, opts) do
    {:ok, opts.vault.decrypt!(bin)}
  rescue
    _ -> :error
  end
end
