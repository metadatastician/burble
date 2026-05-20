# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Burble LLM module tests — covers core query processing, streaming, the
# connection registry, transport endpoint management, protocol frame parsing,
# pool concurrency gating, and provider configuration.

defmodule Burble.LLMTest do
  use ExUnit.Case, async: false

  # A simple test provider that echoes the prompt back.
  defmodule TestProvider do
    def process_query(_user_id, prompt) do
      if String.contains?(prompt, "trigger_error") do
        {:error, :simulated_error}
      else
        {:ok, "Echo: #{prompt}"}
      end
    end

    def stream_query(_user_id, prompt, callback) do
      if String.contains?(prompt, "trigger_error") do
        {:error, :simulated_error}
      else
        for word <- String.split(prompt) do
          callback.(word <> " ")
        end
        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # LLM.process_query/2
  # ---------------------------------------------------------------------------

  describe "LLM.process_query/2" do
    setup do
      Burble.LLM.configure_provider(TestProvider)
      on_exit(fn -> :persistent_term.erase({Burble.LLM, :provider}) end)
    end

    test "returns {:ok, response_string} for a normal prompt" do
      assert {:ok, response} = Burble.LLM.process_query("user_1", "hello world")
      assert is_binary(response)
      assert String.contains?(response, "hello world")
    end

    test "includes the prompt text in the response" do
      prompt = "what is the meaning of life"
      assert {:ok, response} = Burble.LLM.process_query("user_2", prompt)
      assert String.contains?(response, prompt)
    end

    test "returns {:error, :simulated_error} when prompt contains 'trigger_error'" do
      assert {:error, :simulated_error} =
               Burble.LLM.process_query("user_3", "please trigger_error now")
    end
  end

  describe "LLM.process_query/2 without provider" do
    setup do
      :persistent_term.erase({Burble.LLM, :provider})
      :ok
    end

    test "returns {:error, :no_provider_configured} when no provider is set" do
      assert {:error, :no_provider_configured} =
               Burble.LLM.process_query("user_x", "hello")
    end
  end

  # ---------------------------------------------------------------------------
  # LLM.stream_query/3
  # ---------------------------------------------------------------------------

  describe "LLM.stream_query/3" do
    setup do
      Burble.LLM.configure_provider(TestProvider)
      on_exit(fn -> :persistent_term.erase({Burble.LLM, :provider}) end)
    end

    test "calls the callback at least once with a binary chunk" do
      chunks = :ets.new(:test_chunks, [:bag, :public])

      :ok = Burble.LLM.stream_query("user_4", "stream me", fn chunk ->
        :ets.insert(chunks, {:chunk, chunk})
      end)

      recorded = :ets.lookup(chunks, :chunk)
      assert length(recorded) > 0
      Enum.each(recorded, fn {:chunk, c} -> assert is_binary(c) end)
    end

    test "concatenated chunks form a non-empty string" do
      collector = :ets.new(:test_stream_concat, [:ordered_set, :public])
      counter = :counters.new(1, [])

      :ok = Burble.LLM.stream_query("user_5", "anything", fn chunk ->
        idx = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        :ets.insert(collector, {idx, chunk})
      end)

      all_chunks =
        :ets.tab2list(collector)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      full = Enum.join(all_chunks)
      assert String.length(full) > 0
    end

    test "returns :ok" do
      result = Burble.LLM.stream_query("user_6", "ok check", fn _chunk -> :ok end)
      assert result == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # LLM.configure_provider/1
  # ---------------------------------------------------------------------------

  describe "LLM.configure_provider/1" do
    test "sets the provider and subsequent queries use it" do
      :persistent_term.erase({Burble.LLM, :provider})
      assert {:error, :no_provider_configured} = Burble.LLM.process_query("u", "hi")

      Burble.LLM.configure_provider(TestProvider)
      assert {:ok, "Echo: hi"} = Burble.LLM.process_query("u", "hi")

      :persistent_term.erase({Burble.LLM, :provider})
    end
  end

  # ---------------------------------------------------------------------------
  # LLM.Registry
  # ---------------------------------------------------------------------------

  describe "LLM.Registry.register_connection/2 and lookup_connection/1" do
    test "stores the pid and returns it on lookup" do
      user_id = "reg_test_#{:erlang.unique_integer([:positive])}"
      pid = self()

      assert :ok = Burble.LLM.Registry.register_connection(user_id, pid)
      assert {:ok, ^pid} = Burble.LLM.Registry.lookup_connection(user_id)
    end

    test "returns {:error, :not_found} for an unregistered user" do
      user_id = "never_registered_#{:erlang.unique_integer([:positive])}"
      assert {:error, :not_found} = Burble.LLM.Registry.lookup_connection(user_id)
    end

    test "overwrites a previous registration with a new pid" do
      user_id = "overwrite_#{:erlang.unique_integer([:positive])}"
      old_pid = self()

      :ok = Burble.LLM.Registry.register_connection(user_id, old_pid)

      new_pid = spawn(fn -> :timer.sleep(100) end)
      :ok = Burble.LLM.Registry.register_connection(user_id, new_pid)

      assert {:ok, ^new_pid} = Burble.LLM.Registry.lookup_connection(user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # LLM.Transport
  # ---------------------------------------------------------------------------

  describe "LLM.Transport" do
    setup do
      case Process.whereis(Burble.LLM.Transport) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      endpoints = [
        %{host: "primary.test", port: 8503, priority: 1, protocol: :quic, status: :online},
        %{host: "backup.test", port: 8503, priority: 2, protocol: :quic, status: :online},
        %{host: "fallback.test", port: 8085, priority: 3, protocol: :tcp, status: :online}
      ]

      {:ok, pid} = Burble.LLM.Transport.start_link(endpoints: endpoints)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, pid: pid, endpoints: endpoints}
    end

    test "start_link/1 starts the GenServer", %{pid: pid} do
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "get_active_endpoint/0 returns {:ok, endpoint}" do
      assert {:ok, endpoint} = Burble.LLM.Transport.get_active_endpoint()
      assert is_map(endpoint)
      assert Map.has_key?(endpoint, :host)
      assert Map.has_key?(endpoint, :port)
    end

    test "get_active_endpoint/0 selects the highest-priority online endpoint" do
      assert {:ok, endpoint} = Burble.LLM.Transport.get_active_endpoint()
      assert endpoint.host == "primary.test"
      assert endpoint.priority == 1
    end

    test "report_failure/2 marks the endpoint offline and failover selects next" do
      assert {:ok, %{host: "primary.test"}} = Burble.LLM.Transport.get_active_endpoint()

      Burble.LLM.Transport.report_failure("primary.test", 8503)
      _ = :sys.get_state(Burble.LLM.Transport)

      assert {:ok, next} = Burble.LLM.Transport.get_active_endpoint()
      refute next.host == "primary.test"
      assert next.status != :offline
    end
  end

  # ---------------------------------------------------------------------------
  # LLM.Protocol frame parsing
  # ---------------------------------------------------------------------------

  describe "LLM.Protocol frame parsing" do
    setup do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      parent = self()
      # spawn (not Task.async) — Task.shutdown can only be called from the
      # owner pid, but on_exit/1 runs in the ExUnit.OnExitHandler process,
      # which is a different pid (#62).
      acceptor = spawn(fn ->
        {:ok, server} = :gen_tcp.accept(listen, 1000)
        send(parent, {:server_socket, server})
        receive do
          :close -> :gen_tcp.close(server)
        end
      end)

      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])

      server =
        receive do
          {:server_socket, s} -> s
        after
          1000 -> flunk("acceptor did not send server socket in time")
        end

      on_exit(fn ->
        if Process.alive?(acceptor), do: send(acceptor, :close)
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
      end)

      {:ok, client: client, server: server}
    end

    test "parse_frame succeeds for a well-formed QUERY frame", %{client: client, server: server} do
      payload = "QUERY\nid: msg-001\nprompt: hello"
      :ok = :gen_tcp.send(client, payload)

      assert {:ok, frame} = Burble.LLM.Protocol.read_frame(server)
      assert frame[:type] == "QUERY"
      assert frame["id"] == "msg-001"
      assert frame["prompt"] == "hello"
    end

    test "read_frame returns {:error, :closed} when the socket is closed", %{client: client, server: server} do
      :gen_tcp.close(client)
      Process.sleep(20)
      assert {:error, :closed} = Burble.LLM.Protocol.read_frame(server)
    end

    test "parse_frame uppercases the message type", %{client: client, server: server} do
      payload = "stream_start\nid: s-1\nprompt: test"
      :ok = :gen_tcp.send(client, payload)

      assert {:ok, frame} = Burble.LLM.Protocol.read_frame(server)
      assert frame[:type] == "STREAM_START"
    end
  end

  # ---------------------------------------------------------------------------
  # AnthropicProvider (unit, no real API calls)
  # ---------------------------------------------------------------------------

  describe "AnthropicProvider" do
    test "returns {:error, :api_key_not_configured} without ANTHROPIC_API_KEY" do
      old = System.get_env("ANTHROPIC_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")

      assert {:error, :api_key_not_configured} =
               Burble.LLM.AnthropicProvider.process_query("u", "hello")

      if old, do: System.put_env("ANTHROPIC_API_KEY", old)
    end

    test "stream_query returns {:error, :api_key_not_configured} without key" do
      old = System.get_env("ANTHROPIC_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")

      assert {:error, :api_key_not_configured} =
               Burble.LLM.AnthropicProvider.stream_query("u", "hello", fn _ -> :ok end)

      if old, do: System.put_env("ANTHROPIC_API_KEY", old)
    end
  end

  # ---------------------------------------------------------------------------
  # LLM.Supervisor
  # ---------------------------------------------------------------------------

  describe "LLM.Supervisor" do
    test "start_link/1 starts the supervisor with children" do
      case Process.whereis(Burble.LLM.Supervisor) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      assert {:ok, sup_pid} = Burble.LLM.Supervisor.start_link([])
      assert is_pid(sup_pid)
      assert Process.alive?(sup_pid)

      children = Supervisor.which_children(sup_pid)
      assert length(children) > 0

      assert Enum.any?(children, fn {id, _pid, _type, _mods} ->
        id == Burble.LLM.Transport
      end)

      Supervisor.stop(sup_pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Circuit breaker
  # ---------------------------------------------------------------------------

  describe "AnthropicProvider circuit breaker" do
    setup do
      Burble.LLM.AnthropicProvider.reset_circuit_breaker()
      on_exit(fn -> Burble.LLM.AnthropicProvider.reset_circuit_breaker() end)
    end

    test "starts in :closed state" do
      assert Burble.LLM.AnthropicProvider.circuit_breaker_status() == :closed
    end

    test "reset_circuit_breaker/0 resets to :closed" do
      # Force failures by writing directly to ETS
      ensure_cb_table()
      :ets.insert(:burble_llm_circuit_breaker, {:failures, 10})
      :ets.insert(:burble_llm_circuit_breaker, {:opened_at, System.monotonic_time(:millisecond)})

      assert Burble.LLM.AnthropicProvider.circuit_breaker_status() == :open

      Burble.LLM.AnthropicProvider.reset_circuit_breaker()
      assert Burble.LLM.AnthropicProvider.circuit_breaker_status() == :closed
    end

    defp ensure_cb_table do
      case :ets.info(:burble_llm_circuit_breaker) do
        :undefined -> :ets.new(:burble_llm_circuit_breaker, [:set, :public, :named_table])
        _ -> :ok
      end
    end
  end
end
