# SPDX-License-Identifier: MPL-2.0

defmodule Burble.Coprocessor.PipelineSecurityTest do
  use ExUnit.Case, async: true

  alias Burble.Coprocessor.Pipeline

  test "outbound E2EE fails closed when the frame key is invalid" do
    peer_id = "invalid-key-#{System.unique_integer([:positive])}"
    {:ok, pipeline} = Pipeline.start_link(peer_id: peer_id, pipeline_key: <<0>>)

    assert {:error, :encrypt_failed} = Pipeline.process_outbound(pipeline, [0.0, 0.25, -0.25])
    assert {:ok, %{frames_processed: 0}} = Pipeline.health(pipeline)
  end
end
