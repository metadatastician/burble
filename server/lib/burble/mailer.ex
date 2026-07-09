# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Mailer — Email delivery via Swoosh.
#
# Configured per environment:
#   dev:  Swoosh.Adapters.Local (preview at /dev/mailbox)
#   test: Swoosh.Adapters.Test
#   prod: Swoosh.Adapters.SMTP (reads SMTP_HOST/PORT/USER/PASS from env)
#
# Rate limiting:
#   Magic link requests are rate-limited to 3 per email per hour via Hammer.
#   This prevents abuse of the magic link endpoint.

defmodule Burble.Mailer do
  @moduledoc """
  Swoosh mailer for Burble.

  Adapter is set per-environment in config/*.exs. In production,
  SMTP credentials are read from environment variables at boot
  (see config/runtime.exs).
  """

  use Swoosh.Mailer, otp_app: :burble
end

defmodule Burble.Email do
  @moduledoc """
  Email templates for Burble.

  All emails use both plain-text and HTML bodies for maximum
  compatibility across email clients.
  """

  import Swoosh.Email

  @from {"Burble", "noreply@burble.local"}

  @doc """
  Magic link email for passwordless login.

  The link contains a signed token that expires in 15 minutes.
  Includes branding, clear call-to-action, and security notice.

  ## Parameters

    - `to_email` — Recipient email address.
    - `token` — The magic link token (URL-safe base64).
    - `base_url` — The base URL for the Burble instance (default: localhost).
  """
  def magic_link(to_email, token, base_url \\ "http://localhost:6473") do
    link = "#{base_url}/auth/magic?token=#{token}"

    new()
    |> to(to_email)
    |> from(@from)
    |> subject("Sign in to Burble")
    |> text_body("""
    Sign in to Burble
    =================

    Click the link below to sign in:

    #{link}

    This link expires in 15 minutes and can only be used once.

    If you didn't request this, you can safely ignore this email.
    No account will be created unless you click the link.

    — Burble (https://burble.local)
    """)
    |> html_body("""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
    </head>
    <body style="margin: 0; padding: 0; background-color: #f4f4f5; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #f4f4f5;">
        <tr>
          <td align="center" style="padding: 40px 20px;">
            <table role="presentation" width="480" cellspacing="0" cellpadding="0" style="background-color: #ffffff; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
              <!-- Header -->
              <tr>
                <td style="padding: 32px 32px 0; text-align: center;">
                  <h1 style="margin: 0; font-size: 24px; font-weight: 700; color: #1a1a1a;">Burble</h1>
                </td>
              </tr>
              <!-- Body -->
              <tr>
                <td style="padding: 24px 32px;">
                  <h2 style="margin: 0 0 16px; font-size: 20px; color: #1a1a1a;">Sign in to Burble</h2>
                  <p style="margin: 0 0 24px; font-size: 16px; color: #4a4a4a; line-height: 1.5;">
                    Click the button below to sign in. This link expires in <strong>15 minutes</strong>
                    and can only be used once.
                  </p>
                  <table role="presentation" cellspacing="0" cellpadding="0" style="margin: 0 auto;">
                    <tr>
                      <td style="background-color: #4f46e5; border-radius: 6px;">
                        <a href="#{link}" target="_blank"
                           style="display: inline-block; padding: 14px 32px; font-size: 16px;
                                  font-weight: 600; color: #ffffff; text-decoration: none;">
                          Sign In
                        </a>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
              <!-- Security notice -->
              <tr>
                <td style="padding: 0 32px 24px;">
                  <p style="margin: 0; font-size: 13px; color: #9a9a9a; line-height: 1.5;">
                    If you didn't request this email, you can safely ignore it.
                    No account will be created unless you click the link.
                  </p>
                </td>
              </tr>
              <!-- Footer -->
              <tr>
                <td style="padding: 16px 32px; border-top: 1px solid #e5e5e5; text-align: center;">
                  <p style="margin: 0; font-size: 12px; color: #b0b0b0;">
                    Burble &mdash; Open-source voice platform
                  </p>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """)
  end

  @doc """
  Invite email for joining a Burble server.

  Sent when a user is invited to a specific server/community.
  """
  def invite(to_email, invite_token, server_name, base_url \\ "http://localhost:6473") do
    link = "#{base_url}/invite/#{invite_token}"

    new()
    |> to(to_email)
    |> from(@from)
    |> subject("You've been invited to #{server_name} on Burble")
    |> text_body("""
    You've been invited to join #{server_name} on Burble.

    Click the link below to accept:

    #{link}

    — Burble
    """)
    |> html_body("""
    <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; padding: 24px;">
      <h2 style="color: #1a1a1a;">Join #{server_name} on Burble</h2>
      <p>You've been invited to join <strong>#{server_name}</strong>.</p>
      <a href="#{link}" style="display: inline-block; background: #4f46e5; color: white;
         padding: 12px 24px; border-radius: 6px; text-decoration: none; font-weight: bold;">
        Accept Invite
      </a>
    </div>
    """)
  end
end

defmodule Burble.Email.RateLimiter do
  @moduledoc """
  Rate limiting for magic link email requests.

  Uses Hammer to enforce a maximum of 3 magic link requests per email
  address per hour. This prevents abuse of the magic link endpoint
  (e.g. flooding someone's inbox or brute-forcing tokens).

  ## Configuration

  The Hammer backend is configured in config/config.exs:

      config :hammer,
        backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000 * 10]}
  """

  @max_requests 3
  @window_ms 60_000 * 60  # 1 hour in milliseconds

  @doc """
  Check whether a magic link request is allowed for the given email.

  Returns:
    - `{:allow, count}` — Request is allowed; `count` is how many have been sent this window.
    - `{:deny, retry_after_ms}` — Rate limited; `retry_after_ms` indicates when the window resets.

  ## Examples

      iex> Burble.Email.RateLimiter.check_magic_link("user@example.com")
      {:allow, 1}

      iex> # After 3 requests in the same hour:
      iex> Burble.Email.RateLimiter.check_magic_link("user@example.com")
      {:deny, 2_400_000}
  """
  def check_magic_link(email) do
    bucket_key = "magic_link:#{String.downcase(email)}"

    case Hammer.check_rate(bucket_key, @window_ms, @max_requests) do
      {:allow, count} ->
        {:allow, count}

      {:deny, retry_after_ms} ->
        {:deny, retry_after_ms}
    end
  end

  @doc """
  Attempt to send a magic link email, respecting rate limits.

  Combines rate checking with email delivery. Returns:
    - `{:ok, token}` — Email sent successfully.
    - `{:error, :rate_limited, retry_after_ms}` — Too many requests.
    - `{:error, reason}` — Token generation or delivery failed.
  """
  def send_magic_link(email) do
    case check_magic_link(email) do
      {:allow, _count} ->
        # Delegate to Burble.Auth.generate_magic_link/1 which handles
        # token creation, storage, and email delivery.
        Burble.Auth.generate_magic_link(email)

      {:deny, retry_after_ms} ->
        {:error, :rate_limited, retry_after_ms}
    end
  end
end
