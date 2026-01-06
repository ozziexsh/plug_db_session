# PlugDbSession

Use your database as a session store with plug, allowing you to store more than the 4kb cookie limit.

## How it works

The default cookie session store places all data directly into the cookie and then serializes it. There are limitations to that approach because you are restricted to a certain payload size, and you cannot revoke sessions on demand.

The PlugDbSession package still uses cookies, but it offloads all of the data storage to your database:

1. We generate a random session token and store its SHA-256 hash as the database primary key
2. We send the browser an encrypted cookie containing the raw token: `{ "session_id": "<random-token>" }`
3. On subsequent requests, we hash the token from the cookie to look up the session in the database
4. Session data is stored encrypted in the `data` column

This hash-based approach protects against timing attacks - even if encryption is bypassed, an attacker cannot derive valid session tokens from database lookups.

Using this approach, you can:
- store much more data in the session
- store any elixir data type in the session (see ["considerations"](#considerations) below)
- revoke sessions on demand
- see when they were last active
- automatically expire sessions after a configurable lifetime

In the future we will allow arbitrary data to be added to the session schema, allowing you to collect metadata such as tying a session to a user_id, IP, user agent, etc. This can be useful if you e.g. show your logged in users which devices they are logged into and allow them to revoke access on their own.

## Considerations

Under the hood we convert session data using [`:erlang.term_to_binary/1`](https://www.erlang.org/doc/man/erlang.html#term_to_binary-1) and [`:erlang.binary_to_term/1`](https://www.erlang.org/doc/man/erlang.html#binary_to_term-1). This allows you to store any data type in the session and successfully restore it on future loads, however you should make sure you trust the data being stored as there is risk involved, see the documentation for the methods linked above for more info.

If you wish to use a more basic serialization method like `Jason`, see ["Customization"](#encoder--serialization) below.

## Installation

The package can be installed by adding `plug_db_session` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:plug_db_session, "~> 0.1.0"}    
  ]
end
```

You will also need an encryption library, it is recommended to use `cloak`:

```elixir
def deps do
  [    
    {:cloak, "~> 1.1"}
  ]
end
```

You will need to follow the instructions to set up cloak properly before continuing: 

https://hexdocs.pm/cloak/install.html

By now you should have configured your Vault module and set an encryption key.

We need to create a migration and a schema for the sessions table:

```
mix ecto.gen.migration create_sessions_table
```

```elixir
defmodule MyApp.Repo.Migrations.CreateSessionsTable do
  use Ecto.Migration

  def up do
    create table("sessions", primary_key: false) do
      # The ID is a SHA-256 hash of the session token (32 bytes)
      add :id, :binary, null: false, primary_key: true
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

We also need to create a schema for the sessions:

```elixir
# lib/my_app/sessions/session.ex
defmodule MyApp.Sessions.Session do
  use Ecto.Schema

  # The ID is a SHA-256 hash (binary), not auto-generated
  @primary_key {:id, :binary, autogenerate: false}

  schema "sessions" do
    field :data, :binary
    field :last_active_at, :utc_datetime
    field :created_at, :utc_datetime
  end
end
```

Configure PlugDbSession to use our dependencies:

```elixir
config :my_app, PlugDbSession,
  repo: MyApp.Repo,
  schema: MyApp.Sessions.Session,
  vault: MyApp.Vault
```

Update our Endpoint `@session_options` to pass our `otp_app` and the new session store, note that we do not pass any encryption options here as it is taken care of by `cloak`:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  @session_options [
    store: PlugDbSession.Store,
    key: "_my_app_key",
    otp_app: :my_app,
    lifetime: 7200  # optional, defaults to 7200 seconds (2 hours)
  ]
```

And finally add this plug to the end of your `router.ex` browser pipeline to ensure that the `last_active_at` timestamp is set on each request:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, {PhxWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug PlugDbSession.UpdateActivity, otp_app: :my_app # <-- add this line
end
```

That is it! You can now interact with the plug session as you normally would.

## Session Lifetime

By default, sessions expire after 2 hours (7200 seconds) of inactivity. The expiration is based on the `last_active_at` timestamp, which is updated on each request when using `PlugDbSession.UpdateActivity`.

You can customize the lifetime in your endpoint:

```elixir
@session_options [
  store: PlugDbSession.Store,
  key: "_my_app_key",
  otp_app: :my_app,
  lifetime: 86400  # 24 hours in seconds
]
```

To disable automatic expiration entirely, set `lifetime: nil`.

## Session Regeneration

To prevent session fixation attacks, you should regenerate the session ID after authentication state changes (login/logout). Use Plug's built-in `configure_session/2`:

### After Login

Regenerate the session ID while preserving data:

```elixir
conn
|> configure_session(renew: true)
|> put_session(:user_id, user.id)
```

### On Logout

Drop the session entirely:

```elixir
conn
|> configure_session(drop: true)
```

## Pruning / Garbage Collection

Expired sessions are automatically pruned using a lottery system. By default, there's a 2% chance on each request that garbage collection will run asynchronously.

### Lottery Configuration

Configure the lottery odds in your router:

```elixir
# Default: 2% chance (2 out of 100)
plug PlugDbSession.UpdateActivity, otp_app: :my_app

# Custom odds: 5% chance
plug PlugDbSession.UpdateActivity, otp_app: :my_app, lottery: {5, 100}

# Disable lottery (for scheduled job approach)
plug PlugDbSession.UpdateActivity, otp_app: :my_app, lottery: {0, 1}
```

### Scheduled Job (Recommended for High Traffic)

For high-traffic applications, disable the lottery and use a scheduled job instead:

```elixir
# In your Oban worker, Quantum job, etc.
PlugDbSession.UpdateActivity.prune(
  repo: MyApp.Repo,
  schema: MyApp.Sessions.Session,
  lifetime: 7200  # prune sessions older than 2 hours
)
```

## Customization

### @session_options

You can optionally include more data directly in the cookie, though it is not recommended. By default we store an object like `{ session_id: "<token>", _csrf_token: "abcd" }`.

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

### Encoder / Serialization

You can change how the session is serialized to the database by specifying an `:encoder` config. The module must have two methods: `encode!/1` which takes a map and returns a binary/string, and `decode!/1` which takes a binary/string and returns a map. For example, you could use `Jason`:

```elixir
config :my_app, PlugDbSession, ecoder: Jason
```

### Vault

You can swap the encryption module via the config. It must have methods `encrypt!/1` that takes a binary returns a binary, and a `decrypt!/1` method which takes a binary and returns a binary.

```elixir
config :my_app, PlugDbSession, vault: MyApp.CustomEncryption
```

### Schema

The session schema cannot be changed at this point in time, however there are plans to allow that in the future.

The `data` field type could technically be changed if you are not using cloak_ecto, however you must use a data type that allows passing a map when inserting to the database.

