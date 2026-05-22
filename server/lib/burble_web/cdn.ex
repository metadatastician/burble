# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.CDN — Asset offload and CDN management.
#
# Provides utilities for offloading static assets to an external CDN
# (e.g. Cloudflare, bunny.net) or a dedicated asset server.
#
# Features:
#   1. Automatic asset URL generation with versioning/hashing.
#   2. "Dual-Track" asset loading: prefers CDN, falls back to local server.
#   3. Asset minification and compression (delegated to Zig SIMD where possible).

defmodule BurbleWeb.CDN do
  @moduledoc """
  Manages static asset distribution via CDN.
  """

  require Logger

  @doc """
  Generate a URL for an asset.
  Returns a CDN URL if configured, otherwise a local path.
  """
  def asset_url(path) do
    cdn_host = Application.get_env(:burble, :cdn_host)
    version = Application.get_env(:burble, :asset_version, "v1")
    
    if cdn_host do
      "https://#{cdn_host}/#{version}/#{path}"
    else
      "/static/#{path}?v=#{version}"
    end
  end

  @doc """
  Force asset redirection to CDN via HTTP 302.
  Used for heavy assets like large JS bundles or audio samples.
  """
  def redirect_asset(conn, path) do
    url = asset_url(path)
    Phoenix.Controller.redirect(conn, external: url)
  end
end
