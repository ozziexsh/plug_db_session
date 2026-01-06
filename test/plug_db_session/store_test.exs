defmodule PlugDbSession.StoreTest do
  use ExUnit.Case
  alias PlugDbSession.Store

  defmodule Session do
    use Ecto.Schema

    @primary_key {:id, :binary, autogenerate: false}

    schema "sessions" do
      field(:data, :binary, default: <<>>)
      field(:last_active_at, :utc_datetime)
      field(:created_at, :utc_datetime)
    end
  end

  defmodule Vault do
    def encrypt!(val), do: val
    def decrypt!(val), do: val
  end


  defmodule TestRepo do
    # Store sessions in process dictionary for test isolation
    def insert!(session) do
      sessions = Process.get(:test_sessions, %{})
      Process.put(:test_sessions, Map.put(sessions, session.id, session))
      session
    end

    def get(Session, id) do
      sessions = Process.get(:test_sessions, %{})
      Map.get(sessions, id)
    end

    def update!(changeset) do
      session = Map.merge(changeset.data, changeset.changes)
      sessions = Process.get(:test_sessions, %{})
      Process.put(:test_sessions, Map.put(sessions, session.id, session))
      session
    end

    def delete(_session) do
      :ok
    end
  end

  @opts %{
    schema: Session,
    encoder: PlugDbSession.Encoder,
    vault: Vault,
    repo: TestRepo,
    cookie_keys: []
  }

  setup do
    # Reset test sessions before each test
    Process.put(:test_sessions, %{})

    # Pre-populate a session with known token hash
    known_session = %Session{
      id: :crypto.hash(:sha256, "test-token-with-data"),
      data: :erlang.term_to_binary(%{"foo" => "bar"}),
      last_active_at: DateTime.utc_now() |> DateTime.truncate(:second),
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Process.put(:test_sessions, %{known_session.id => known_session})
    :ok
  end

  describe "init" do
    test "it sets defaults when none specified" do
      opts = Store.init(otp_app: :my_app)

      assert opts == %{
               cookie_keys: ["session_id", "_csrf_token"],
               vault: nil,
               repo: nil,
               schema: nil,
               encoder: PlugDbSession.Encoder
             }
    end

    test "it can override cookie keys" do
      assert %{cookie_keys: ["session_id"]} = Store.init(cookie_keys: [])

      assert %{cookie_keys: ["session_id", "one", "two"]} =
               Store.init(cookie_keys: ["one", "two"])
    end
  end

  describe "get" do
    test "it creates a new session when cookie is not present" do
      {token, data} = Store.get(nil, nil, @opts)

      # Token should be a base64url encoded string (43 chars for 32 bytes)
      assert is_binary(token)
      assert String.length(token) == 43
      assert data == %{}

      # Verify session was stored with hashed ID
      hashed_id = :crypto.hash(:sha256, token)
      assert TestRepo.get(Session, hashed_id) != nil
    end

    test "it creates a new session when token is present in cookie but not found in db" do
      unknown_token = "unknown-token-xyz"
      fake_cookie = %{"session_id" => unknown_token} |> :erlang.term_to_binary() |> Base.encode64(padding: false)

      {token, data} = Store.get(nil, fake_cookie, @opts)

      # Should create a new session with a new token
      assert is_binary(token)
      assert data == %{}
    end

    test "it creates a new session when no session_id is found in the cookie" do
      fake_cookie = %{} |> :erlang.term_to_binary() |> Base.encode64(padding: false)

      {token, data} = Store.get(nil, fake_cookie, @opts)

      assert is_binary(token)
      assert data == %{}
    end

    test "it returns the session data when it finds a matching session" do
      known_token = "test-token-with-data"
      fake_cookie = %{"session_id" => known_token} |> :erlang.term_to_binary() |> Base.encode64(padding: false)

      {token, data} = Store.get(nil, fake_cookie, @opts)

      assert token == known_token
      assert data == %{"foo" => "bar"}
    end
  end

  describe "put" do
    test "it creates a new session when no session token present" do
      cookie = Store.put(nil, nil, %{"bar" => "baz"}, @opts)
      decrypted = cookie |> Base.decode64!(padding: false) |> :erlang.binary_to_term()

      # Cookie should contain a session_id token
      assert Map.has_key?(decrypted, "session_id")
      token = decrypted["session_id"]
      assert is_binary(token)
      assert String.length(token) == 43
    end

    test "it creates a new session when the session cant be found" do
      cookie = Store.put(nil, "nonexistent-token", %{"bar" => "baz"}, @opts)
      decrypted = cookie |> Base.decode64!(padding: false) |> :erlang.binary_to_term()

      assert Map.has_key?(decrypted, "session_id")
    end

    test "it returns the existing session token when found, and only the keys in cookie_keys" do
      known_token = "test-token-with-data"
      cookie =
        Store.put(nil, known_token, %{"bar" => "baz", "foo" => "bar"}, %{@opts | cookie_keys: ["session_id", "bar"]})

      decrypted = cookie |> Base.decode64!(padding: false) |> :erlang.binary_to_term()

      assert decrypted["session_id"] == known_token
      assert decrypted["bar"] == "baz"
      refute Map.has_key?(decrypted, "foo")
    end
  end

  describe "delete" do
    test "it deletes a session by hashing the token" do
      known_token = "test-token-with-data"

      # Verify session exists before delete
      hashed_id = :crypto.hash(:sha256, known_token)
      assert TestRepo.get(Session, hashed_id) != nil

      assert :ok = Store.delete(nil, known_token, @opts)
    end
  end

  describe "hashing" do
    test "the same token always produces the same hash" do
      token = "consistent-token"
      hash1 = :crypto.hash(:sha256, token)
      hash2 = :crypto.hash(:sha256, token)

      assert hash1 == hash2
    end

    test "different tokens produce different hashes" do
      hash1 = :crypto.hash(:sha256, "token-1")
      hash2 = :crypto.hash(:sha256, "token-2")

      refute hash1 == hash2
    end
  end
end
