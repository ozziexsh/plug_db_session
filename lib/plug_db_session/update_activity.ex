defmodule PlugDbSession.UpdateActivity do
  @moduledoc """
  Plug that forces the session to update at the end of the request, causing the last_active_at timestamp to update.

  Also implements a lottery-based garbage collection system to prune expired sessions.

  ## Options

    * `:otp_app` - (required) your OTP app atom, used to read PlugDbSession config
    * `:lottery` - (optional) tuple of `{chance, out_of}` for GC probability. Defaults to `{2, 100}` (2% chance).
      Set to `{0, 1}` to disable lottery-based pruning.

  ## Example

      plug PlugDbSession.UpdateActivity, otp_app: :my_app

      # Custom lottery odds (1 in 50 = 2%)
      plug PlugDbSession.UpdateActivity, otp_app: :my_app, lottery: {1, 50}

      # Disable lottery pruning (use scheduled job instead)
      plug PlugDbSession.UpdateActivity, otp_app: :my_app, lottery: {0, 1}

  ## Garbage Collection

  On each request, there's a configurable probability (default 2%) that expired sessions
  will be pruned from the database. This uses the `lifetime` value from your session options
  to determine which sessions are expired.

  The pruning runs asynchronously and won't block the request.

  For high-traffic applications, consider disabling the lottery and using a scheduled job instead:

      # In a scheduled job (e.g., Oban, Quantum)
      PlugDbSession.UpdateActivity.prune(repo: MyApp.Repo, schema: MyApp.Session, lifetime: 7200)

  """

  @behaviour Plug

  import Ecto.Query

  @default_lottery {2, 100}

  @doc false
  @impl Plug
  def init(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    config = Application.get_env(otp_app, PlugDbSession, [])

    %{
      repo: Keyword.fetch!(config, :repo),
      schema: Keyword.fetch!(config, :schema),
      lottery: Keyword.get(opts, :lottery, @default_lottery),
      lifetime: Keyword.get(opts, :lifetime, 7200)
    }
  end

  @doc false
  @impl Plug
  def call(conn, opts) do
    maybe_prune(opts)
    Plug.Conn.put_private(conn, :plug_session_info, :write)
  end

  @doc """
  Prunes expired sessions from the database.

  This can be called directly from a scheduled job if you prefer deterministic
  cleanup over the lottery system.

  ## Options

    * `:repo` - (required) the Ecto repo module
    * `:schema` - (required) the session schema module
    * `:lifetime` - (required) session lifetime in seconds

  ## Example

      # Delete sessions older than 2 hours
      PlugDbSession.UpdateActivity.prune(
        repo: MyApp.Repo,
        schema: MyApp.Sessions.Session,
        lifetime: 7200
      )

  Returns `{count, nil}` where count is the number of deleted sessions.
  """
  def prune(opts) do
    repo = Keyword.fetch!(opts, :repo)
    schema = Keyword.fetch!(opts, :schema)
    lifetime = Keyword.fetch!(opts, :lifetime)

    cutoff = DateTime.utc_now() |> DateTime.add(-lifetime, :second)

    from(s in schema, where: s.last_active_at < ^cutoff)
    |> repo.delete_all()
  end

  defp maybe_prune(%{lottery: {0, _}}), do: :ok

  defp maybe_prune(%{lottery: {chance, out_of}} = opts) do
    if :rand.uniform(out_of) <= chance do
      Task.start(fn -> prune(repo: opts.repo, schema: opts.schema, lifetime: opts.lifetime) end)
    end

    :ok
  end
end
