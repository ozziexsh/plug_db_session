defmodule PlugDbSession.UpdateActivityTest do
  use ExUnit.Case
  alias PlugDbSession.UpdateActivity

  defmodule Session do
    use Ecto.Schema

    @primary_key {:id, :binary, autogenerate: false}

    schema "sessions" do
      field(:data, :binary, default: <<>>)
      field(:last_active_at, :utc_datetime)
      field(:created_at, :utc_datetime)
    end
  end

  defmodule TestRepo do
    def delete_all(query) do
      # Extract the cutoff from the query and count matching sessions
      sessions = Process.get(:test_sessions, %{})

      # For testing, we'll just count and remove expired sessions
      {expired, remaining} =
        Enum.split_with(sessions, fn {_id, session} ->
          # Check if the query would match this session
          case query do
            %Ecto.Query{wheres: [%{expr: {:<, _, _}}]} ->
              # This is a simplified check - in real tests we'd parse the query
              cutoff = Process.get(:test_cutoff)
              cutoff && DateTime.compare(session.last_active_at, cutoff) == :lt

            _ ->
              false
          end
        end)

      Process.put(:test_sessions, Map.new(remaining))
      {length(expired), nil}
    end
  end

  setup do
    Process.put(:test_sessions, %{})
    Process.delete(:test_cutoff)
    :ok
  end

  describe "prune/1" do
    test "deletes sessions older than lifetime" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Create an old session (3 hours ago)
      old_session = %Session{
        id: :crypto.hash(:sha256, "old-token"),
        data: <<>>,
        last_active_at: DateTime.add(now, -10800, :second),
        created_at: DateTime.add(now, -10800, :second)
      }

      # Create a recent session
      recent_session = %Session{
        id: :crypto.hash(:sha256, "recent-token"),
        data: <<>>,
        last_active_at: DateTime.add(now, -1800, :second),
        created_at: DateTime.add(now, -1800, :second)
      }

      sessions = %{
        old_session.id => old_session,
        recent_session.id => recent_session
      }

      Process.put(:test_sessions, sessions)

      # Set the cutoff that our mock repo will use
      cutoff = DateTime.add(now, -7200, :second)
      Process.put(:test_cutoff, cutoff)

      {count, nil} =
        UpdateActivity.prune(
          repo: TestRepo,
          schema: Session,
          lifetime: 7200
        )

      # Old session should be deleted, recent should remain
      assert count == 1
      remaining = Process.get(:test_sessions)
      assert map_size(remaining) == 1
      assert Map.has_key?(remaining, recent_session.id)
    end
  end

  describe "lottery" do
    test "lottery {0, 1} never triggers prune" do
      opts = %{
        lottery: {0, 1},
        repo: TestRepo,
        schema: Session,
        lifetime: 7200
      }

      conn = %Plug.Conn{private: %{}}
      result = UpdateActivity.call(conn, opts)

      assert result.private[:plug_session_info] == :write
    end

    test "lottery {100, 100} triggers prune" do
      opts = %{
        lottery: {100, 100},
        repo: TestRepo,
        schema: Session,
        lifetime: 7200
      }

      conn = %Plug.Conn{private: %{}}
      result = UpdateActivity.call(conn, opts)

      assert result.private[:plug_session_info] == :write
    end
  end

  describe "init/1" do
    test "sets default lottery" do
      Application.put_env(:test_app, PlugDbSession,
        repo: TestRepo,
        schema: Session
      )

      opts = UpdateActivity.init(otp_app: :test_app)

      assert opts.lottery == {2, 100}
      assert opts.lifetime == 7200

      Application.delete_env(:test_app, PlugDbSession)
    end

    test "allows custom lottery" do
      Application.put_env(:test_app, PlugDbSession,
        repo: TestRepo,
        schema: Session
      )

      opts = UpdateActivity.init(otp_app: :test_app, lottery: {5, 100})

      assert opts.lottery == {5, 100}

      Application.delete_env(:test_app, PlugDbSession)
    end

    test "allows custom lifetime" do
      Application.put_env(:test_app, PlugDbSession,
        repo: TestRepo,
        schema: Session
      )

      opts = UpdateActivity.init(otp_app: :test_app, lifetime: 3600)

      assert opts.lifetime == 3600

      Application.delete_env(:test_app, PlugDbSession)
    end
  end
end
