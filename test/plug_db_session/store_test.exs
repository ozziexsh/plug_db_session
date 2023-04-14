defmodule PlugDbSession.StoreTest do
  use ExUnit.Case
  alias PlugDbSession.Store

  defmodule Session do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "sessions" do
      field(:data, :map, default: %{})
      field(:last_active_at, :utc_datetime)
      field(:created_at, :utc_datetime)
    end
  end

  defmodule Vault do
    def encrypt!(val), do: val
    def decrypt!(val), do: val
  end

  defmodule GoodRepo do
    @session %Session{id: "1"}
    @sessions [
      %Session{id: "2"},
      %Session{id: "3", data: %{"foo" => "bar"}},
      %Session{id: "4"}
    ]

    def insert!(_), do: @session

    def get(_, id), do: Enum.find(@sessions, &(&1.id == id))

    def update!(x), do: Map.merge(x.data, x.changes)
  end

  @opts %{schema: Session, json: Jason, vault: Vault, repo: GoodRepo, cookie_keys: []}

  describe "init" do
    test "it sets defaults when none specified" do
      opts = Store.init(otp_app: :my_app)

      assert opts == %{
               cookie_keys: ["session_id", "_csrf_token"],
               vault: nil,
               repo: nil,
               schema: nil,
               json: nil
             }
    end

    test "it can override cookie keys" do
      assert %{cookie_keys: ["session_id"]} = Store.init(cookie_keys: [])

      assert %{cookie_keys: ["session_id", "one", "two"]} =
               Store.init(cookie_keys: ["one", "two"])
    end
  end

  describe "get" do
    # in theory never happens (see put/4) but good to know it'll work
    test "it creates a new session when cookie is not present" do
      assert {"1", %{}} == Store.get(nil, nil, @opts)
    end

    test "it creates a new session when an id is present in the cookie but not found in the db" do
      fake_cookie = %{"session_id" => "1234"} |> Jason.encode!() |> Base.encode64()

      assert {"1", %{}} == Store.get(nil, fake_cookie, @opts)
    end

    test "it creates a new session when no id is found in the cookie" do
      fake_cookie = %{} |> Jason.encode!() |> Base.encode64()

      assert {"1", %{}} == Store.get(nil, fake_cookie, @opts)
    end

    test "it returns the session data when it finds a matching session" do
      fake_cookie = %{"session_id" => "3"} |> Jason.encode!() |> Base.encode64()

      assert {"3", %{"foo" => "bar"}} == Store.get(nil, fake_cookie, @opts)
    end
  end

  describe "put" do
    test "it creates a new session when no session id present" do
      cookie = Store.put(nil, nil, %{"bar" => "baz"}, @opts)
      decrypted = cookie |> Base.decode64!() |> Jason.decode!()

      assert decrypted == %{"session_id" => "1"}
    end

    test "it creates a new session when the session cant be found" do
      cookie = Store.put(nil, "1234", %{"bar" => "baz"}, @opts)
      decrypted = cookie |> Base.decode64!() |> Jason.decode!()

      assert decrypted == %{"session_id" => "1"}
    end

    test "it returns the existing session id when found, and only the keys in cookie_keys" do
      cookie =
        Store.put(nil, "3", %{"bar" => "baz", "foo" => "bar"}, %{@opts | cookie_keys: ["bar"]})

      decrypted = cookie |> Base.decode64!() |> Jason.decode!()

      assert decrypted == %{"session_id" => "3", "bar" => "baz"}
    end
  end
end
