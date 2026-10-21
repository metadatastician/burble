# gen-e2ee-vectors.exs — regenerate the E2EE cross-language test vectors.
#
#   cd server
#   elixirc lib/burble/media/e2ee.ex -o /tmp/ebin
#   elixir -pa /tmp/ebin ../scripts/gen-e2ee-vectors.exs \
#     > ../client/web/tests/fixtures/e2ee-vectors.json
#
# Everything here uses the *shipped* functions from
# server/lib/burble/media/e2ee.ex — nothing is reimplemented in the script.
# The companion verifier (scripts/verify-e2ee-vectors.mjs) re-derives the same
# values with WebCrypto, i.e. the primitives the browser half must use.
#
# Regenerate only when the protocol changes (labels, AAD, derivation). A change
# that alters the output is a wire break and belongs in an ADR.

alias Burble.Media.E2EE

hexdec = fn h -> Base.decode16!(h, case: :mixed) end
enc16 = fn b -> Base.encode16(b, case: :lower) end

# RFC 7748 §6.1 test private keys, so the vectors are checkable against a
# published document as well as against each other.
priv_a = hexdec.("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
priv_b = hexdec.("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")

{pub_a, ^priv_a} = :crypto.generate_key(:ecdh, :x25519, priv_a)
{pub_b, ^priv_b} = :crypto.generate_key(:ecdh, :x25519, priv_b)

room = "room-1"
epoch = 3
alice = "alice"
bob = "bob"
group_key = hexdec.("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")

{:ok, pairwise} = E2EE.pairwise_key(priv_a, pub_b, room, epoch, alice, bob)
# Symmetry is part of the contract.
{:ok, ^pairwise} = E2EE.pairwise_key(priv_b, pub_a, room, epoch, bob, alice)

{:ok, sealed} = E2EE.seal_group_key(group_key, pairwise, room, epoch, alice, bob)
{:ok, ^group_key} = E2EE.open_group_key(sealed, pairwise, room, epoch, alice, bob)

wire = E2EE.encode_sealed(sealed)

frame_0 = E2EE.derive_frame_key(group_key, epoch, 0)
frame_1 = E2EE.derive_frame_key(group_key, epoch, 1)

IO.puts("""
{
  "source": "Elixir Burble.Media.E2EE",
  "rfc7748_private_a": "#{enc16.(priv_a)}",
  "rfc7748_private_b": "#{enc16.(priv_b)}",
  "public_a": "#{enc16.(pub_a)}",
  "public_b": "#{enc16.(pub_b)}",
  "room": "#{room}",
  "epoch": #{epoch},
  "from": "#{alice}",
  "to": "#{bob}",
  "group_key": "#{enc16.(group_key)}",
  "pairwise_key": "#{enc16.(pairwise)}",
  "sealed_wire_b64": "#{Base.encode64(wire)}",
  "frame_key_0": "#{enc16.(frame_0)}",
  "frame_key_1": "#{enc16.(frame_1)}"
}
""")
