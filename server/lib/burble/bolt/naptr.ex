# SPDX-License-Identifier: MPL-2.0
#
# Burble.Bolt.NAPTR — DNS resolution for bolt-by-domain targets.
#
# Allows `burble bolt user@example.com` to find the target's Burble server
# without knowing its IP in advance, using standard DNS service discovery.
#
# Resolution order:
#   1. NAPTR record: query <domain> for NAPTR with service tag "BURBLE+bolt"
#      regexp field is a sed-style substitution, e.g.:
#        !.*!bolt://192.168.1.100:7373!
#      replacement field can also be used (points to a hostname).
#
#   2. SRV record: _burble._bolt._udp.<domain>
#      Standard DNS SRV (RFC 2782). Returns priority, weight, port, target.
#
#   3. A/AAAA fallback: resolve <domain> directly, use default port 7373.
#
# DNS operators can publish Burble bolt reachability like this:
#
#   example.com. IN NAPTR 10 1 "U" "BURBLE+bolt" "!.*!bolt://198.51.100.1:7373!" .
#   _burble._bolt._udp.example.com. IN SRV 10 1 7373 burble.example.com.

defmodule Burble.Bolt.NAPTR do
  require Logger

  alias Burble.Bolt.{Packet, Sender}

  @bolt_port Packet.port()

  @type resolved :: %{ip: tuple(), port: non_neg_integer(), via: :naptr | :srv | :a}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Resolve a domain (or user@domain) to a bolt target IP+port.

  Returns `{:ok, %{ip: tuple, port: integer, via: atom}}` or `{:error, reason}`.
  """
  @spec resolve(String.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve(address) do
    domain = extract_domain(address)

    with {:error, _} <- resolve_naptr(domain),
         {:error, _} <- resolve_srv(domain),
         {:error, _} <- resolve_a(domain) do
      {:error, {:no_bolt_record, domain}}
    end
  end

  @doc """
  Resolve `address` and send a Bolt to the result.

  This is the NAPTR entry point: `burble bolt user@example.com`.
  """
  @spec send(String.t(), keyword()) :: :ok | {:error, term()}
  def send(address, opts \\ []) do
    case resolve(address) do
      {:ok, %{ip: ip, port: _port, via: via}} ->
        Logger.debug("[Bolt] NAPTR resolved #{address} → #{inspect(ip)} via #{via}")
        target = {ip, nil}
        Sender.send(target, Keyword.merge(opts, naptr_routed: true))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — NAPTR
  # ---------------------------------------------------------------------------

  defp resolve_naptr(domain) do
    charlist = String.to_charlist(domain)

    case :inet_res.lookup(charlist, :in, :naptr) do
      [] ->
        {:error, :no_naptr}

      records ->
        # Records: [{order, pref, flags, services, regexp, replacement}]
        burble_records =
          records
          |> Enum.filter(fn {_o, _p, _f, services, _rx, _rep} ->
            services = List.to_string(services)
            String.contains?(String.upcase(services), "BURBLE")
          end)
          |> Enum.sort_by(fn {order, pref, _, _, _, _} -> {order, pref} end)

        case burble_records do
          [] -> {:error, :no_burble_naptr}

          [{_order, _pref, _flags, _services, regexp, replacement} | _] ->
            parse_naptr_result(regexp, replacement)
        end
    end
  rescue
    _ -> {:error, :naptr_lookup_failed}
  end

  defp parse_naptr_result(regexp, replacement) do
    regexp_str = List.to_string(regexp)

    cond do
      # Regexp present: sed-style !pattern!replacement! — extract bolt:// URI
      regexp_str != "" ->
        case extract_uri_from_regexp(regexp_str) do
          {:ok, uri} -> parse_bolt_uri(uri)
          err -> err
        end

      # No regexp: replacement is a hostname
      replacement != [] and replacement != "" ->
        host = List.to_string(replacement)
        resolve_a(host)

      true ->
        {:error, :empty_naptr}
    end
  end

  # Extracts the replacement from a sed-style regexp: !.*!bolt://host:port!
  defp extract_uri_from_regexp(regexp) do
    # Split on the separator character (first char after empty prefix)
    case String.split(regexp, "", parts: 2) do
      [_, rest] ->
        sep = String.first(rest)
        parts = String.split(rest, sep)
        case parts do
          [_pattern, replacement | _] -> {:ok, replacement}
          _ -> {:error, :bad_naptr_regexp}
        end
      _ ->
        {:error, :bad_naptr_regexp}
    end
  end

  defp parse_bolt_uri("bolt://" <> rest) do
    case String.split(rest, ":") do
      [host, port_str] ->
        with {port, ""} <- Integer.parse(port_str),
             {:ok, ip} <- resolve_host(host) do
          {:ok, %{ip: ip, port: port, via: :naptr}}
        else
          _ -> {:error, :bad_bolt_uri}
        end

      [host] ->
        with {:ok, ip} <- resolve_host(host) do
          {:ok, %{ip: ip, port: @bolt_port, via: :naptr}}
        end

      _ -> {:error, :bad_bolt_uri}
    end
  end

  defp parse_bolt_uri(_), do: {:error, :not_bolt_uri}

  # ---------------------------------------------------------------------------
  # Private — SRV
  # ---------------------------------------------------------------------------

  defp resolve_srv(domain) do
    srv_name = String.to_charlist("_burble._bolt._udp.#{domain}")

    case :inet_res.lookup(srv_name, :in, :srv) do
      [] -> {:error, :no_srv}

      records ->
        # Records: [{priority, weight, port, target}]
        [{_prio, _weight, port, target} | _] =
          Enum.sort_by(records, fn {p, w, _, _} -> {p, -w} end)

        target_str = List.to_string(target)
        case resolve_host(target_str) do
          {:ok, ip} -> {:ok, %{ip: ip, port: port, via: :srv}}
          err -> err
        end
    end
  rescue
    _ -> {:error, :srv_lookup_failed}
  end

  # ---------------------------------------------------------------------------
  # Private — A/AAAA fallback
  # ---------------------------------------------------------------------------

  defp resolve_a(domain) do
    case resolve_host(domain) do
      {:ok, ip} -> {:ok, %{ip: ip, port: @bolt_port, via: :a}}
      err -> err
    end
  end

  defp resolve_host(host) do
    charlist = String.to_charlist(host)
    case :inet.getaddr(charlist, :inet) do
      {:ok, ip} -> {:ok, ip}
      _ ->
        case :inet.getaddr(charlist, :inet6) do
          {:ok, ip} -> {:ok, ip}
          {:error, reason} -> {:error, {:dns_failed, host, reason}}
        end
    end
  end

  defp extract_domain(address) do
    case String.split(address, "@") do
      [_user, domain] -> domain
      [domain] -> domain
    end
  end
end
