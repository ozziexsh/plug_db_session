# PlugDbSession

Use your database as a session store with plug, allowing you to store more than the 4kb cookie limit.

## How it works

The default cookie session store places all data directly into the cookie and then serializes it. There are limitations to that approach because you are restricted to a certain payload size, and you cannot revoke sessions on demand.

The PlugDbSession package still uses cookies, but it offloads all of the data storage to your database:

1. We create a record in the database with a unique ID like `{ id: "some-uuid", data: <encrypted json>, last_active_at: "2023-01-01T00:00Z" }`
2. We send the browser a cookie that looks like `{ "session_id": "some-uuid" }`
3. When you set session data in your app, instead of adding to that cookie we look up the row in the  `sessions` table and update the `data` column (encrypted json)

Using this approach, you can store much more data in the session, revoke sessions on demand, and see when they were last active.

In the future we will allow arbitrary data to be added to the session schema, allowing you to collect metadata such as tying a sessio to a user_id, IP, user agent, etc. This can be useful if you e.g. show your logged in users which devices they are logged into and allow them to revoke access on their own.

## Installation

The package can be installed by adding `plug_db_session` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:plug_db_session, "~> 0.1.0"}    
  ]
end
```

The following dependencies are recommended for using this package. Technically these are configurable (see [Customization](#customization) below) but for the purpose of the installation steps we will assume you are using the recommended ones.

```elixir
def deps do
  [    
    # recommended dependencies
    {:cloak, "~> 1.1"},
    {:cloak_ecto, "~> 1.2.0"},
    {:jason, "~> 1.2"}
  ]
end
```

You will need to follow the instructions to set up cloak properly: 

https://hexdocs.pm/cloak/install.html

By now you should have configured your apps' Vault module and set an encryption key.

We need to create a migration and a schema for the sessions table:

```
mix ecto.gen.migration create_sessions_table
```

```elixir
defmodule MyApp.Repo.Migrations.CreateSessionsTable do
  use Ecto.Migration

  def up do
    create table("sessions", primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :data, :binary, null: false
      add :last_active_at, :utc_datetime, null: false, default: fragment("now()")
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
    end
  end

  def down do
    drop table("sessions")
  end
end
```

We also need to create a schema for the sessions. It is HIGHLY recommended to setup cloak_ecto and use an encrypted map ecto type. https://hexdocs.pm/cloak_ecto/Cloak.Ecto.Map.html#content

```elixir
# lib/my_app/sessions/session.ex
defmodule MyApp.Sessions.Session do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sessions" do
    field :data, MyApp.Encrypted.Map
    field :last_active_at, :utc_datetime
    field :created_at, :utc_datetime
  end
end
```

Now we can configure PlugDbSession:

```elixir
config :my_app, PlugDbSession,
  repo: MyApp.Repo,
  vault: MyApp.Vault,
  json: Jason,
  schema: MyApp.Sessions.Session
```

Next we need to update our Endpoint

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  @session_options [
    store: PlugDbSession.Store,
    key: "_my_app_key",
    otp_app: :my_app
  ]
```

And finally add this plug to the end of your `router.ex` browser pipeline

```diff
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, {PhxWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
+ plug PlugDbSession.UpdateActivity
end
```

## Pruning

There will come a time when unused sessions start to build up in your database. For the most part, if you are logging users out with `configure_session(drop: true)` then the session will be deleted from the database. As it happens though, you will likely have a lot of users visit your website once or twice then never again, thus leaving a useless inactive row in your database.

There is a plan to add automatic pruning to the database directly in the package, however until that is implemented you will likely want to run a job once every X days depending on the size of your app that does something like:

```elixir
from (
  s in Session,
  where: s.last_active_at < datetime_add(^DateTime.utc_now(), -1, "month")
)
|> MyRepo.delete_all()
```

## Customization

### @session_options

You can optionally include more data directly in the cookie, though it is not recommended. By default we store an object like `{ session_id: 10, _csrf_token: "abcd" }`.

If you want to customize this, do so in the endpoint:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  @session_options [
    store: PlugDbSession.Store,
    key: "_my_app_key",
    otp_app: :my_app,
    cookie_keys: ["_csrf_token", "user_id"]
  ]
```

Values will be taken from the session data matching the provided keys and added directly to the cookie. If you overwrite this value you must pass `_csrf_token` manually again so that csrf protection continues to work. Likewise, if your app is not using csrf protection or you are using a different key, you can either omit it all together or enter your custom key here.

### JSON

You can swap the json encoder via the config. It must have methods `encode!/1` that takes a map and returns a string, and `decode!/1` that takes a string and returns a map.

```elixir
config :my_app, PlugDbSession, json: Poison
```

### Vault

You can swap the encryption module via the config. It must have methods `encrypt!/1` that takes a string and returns a string, and a `decrypt!/1` method which takes a string and returns a string.

```elixir
config :my_app, PlugDbSession, vault: MyApp.CustomEncryption
```

### Schema

The session schema cannot be changed at this point in time, however there are plans to allow that in the future.

The `data` field type could technically be changed if you are not using cloak_ecto, however you must use a data type that allows passing a map when inserting to the database.
