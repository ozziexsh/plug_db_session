defmodule PlugDbSession.Encoder do
  @moduledoc """
  Encodes and decodes session data for storing in the database
  """

  @doc false
  def encode!(term), do: :erlang.term_to_binary(term)

  @doc false
  def decode!(bin), do: :erlang.binary_to_term(bin)
end
