# SPDX-License-Identifier: MPL-2.0

defmodule Burble.RoomNamer do
  @moduledoc """
  Generates secure, user-friendly room names using three random words.
  
  Requirements:
  - Words are common across languages
  - No homophones or confusing letters
  - Available on international keyboards without modifiers
  - Concrete, relatable nouns only
  """
  
  @wordlist [
    "apple", "banana", "cat", "dog", "elephant", "fish", "garden", "house",
    "igloo", "jungle", "kite", "lemon", "mountain", "notebook", "orange",
    "pencil", "queen", "river", "sun", "tree", "umbrella", "violin",
    "water", "xylophone", "yellow", "zebra", "book", "chair", "desk",
    "door", "floor", "glass", "hand", "island", "jacket", "kitchen",
    "lamp", "mirror", "nest", "ocean", "paper", "quilt", "radio",
    "shoe", "table", "violin", "window", "yard", "zero"
  ]
  
  @wordlist_size length(@wordlist)
  
  @doc "Returns the list of words used for generating room names."
  def wordlist, do: @wordlist

  @doc """
  Generates a secure room name using three random words.
  
  Uses cryptographically secure random number generation.
  
  ## Examples

      iex> Burble.RoomNamer.generate_room_name()
      "apple-banana-cat"
  """
  def generate_room_name do
    :crypto.strong_rand_bytes(3)
    |> do_generate_room_name()
  end
  
  defp do_generate_room_name(<<a, b, c>>) do
    word_a = Enum.at(@wordlist, rem(a, @wordlist_size))
    word_b = Enum.at(@wordlist, rem(b, @wordlist_size))
    word_c = Enum.at(@wordlist, rem(c, @wordlist_size))
    "#{word_a}-#{word_b}-#{word_c}"
  end
  
  @doc """
  Validates a room name format.
  
  Returns true if the name matches the three-words pattern.
  """
  def valid_room_name?(name) when is_binary(name) do
    String.match?(name, ~r/^[a-z]+-[a-z]+-[a-z]+$/)
  end
end