# SPDX-License-Identifier: MPL-2.0

defmodule Burble.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Burble.CircuitBreaker

  setup do
    name = String.to_atom("cb_test_#{System.unique_integer([:positive])}")
    CircuitBreaker.register(name, failure_threshold: 3, open_duration_ms: 50)
    %{name: name}
  end

  describe "with_breaker/2" do
    test "passes successful results through unchanged", %{name: name} do
      assert {:ok, :pong} = CircuitBreaker.with_breaker(name, fn -> {:ok, :pong} end)
      assert :closed = CircuitBreaker.state(name)
    end

    test "passes failure results through unchanged", %{name: name} do
      assert {:error, :boom} = CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
    end

    test "opens after threshold consecutive failures", %{name: name} do
      for _ <- 1..3 do
        CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      end

      assert :open = CircuitBreaker.state(name)
      assert {:error, :circuit_open} = CircuitBreaker.with_breaker(name, fn -> {:ok, :unused} end)
    end

    test "successes reset the failure counter", %{name: name} do
      CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      CircuitBreaker.with_breaker(name, fn -> {:ok, :recovered} end)
      CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)

      assert :closed = CircuitBreaker.state(name)
    end

    test "moves to half-open after the open window elapses", %{name: name} do
      for _ <- 1..3, do: CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      assert :open = CircuitBreaker.state(name)

      Process.sleep(60)
      assert :half_open = CircuitBreaker.state(name)
    end

    test "half-open success closes the circuit", %{name: name} do
      for _ <- 1..3, do: CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      Process.sleep(60)

      assert {:ok, :ok} = CircuitBreaker.with_breaker(name, fn -> {:ok, :ok} end)
      assert :closed = CircuitBreaker.state(name)
    end

    test "half-open failure re-opens the circuit", %{name: name} do
      for _ <- 1..3, do: CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      Process.sleep(60)

      assert {:error, :still_broken} =
               CircuitBreaker.with_breaker(name, fn -> {:error, :still_broken} end)

      assert :open = CircuitBreaker.state(name)
    end

    test "exceptions count as failures and propagate", %{name: name} do
      for _ <- 1..3 do
        assert_raise RuntimeError, fn ->
          CircuitBreaker.with_breaker(name, fn -> raise "kaboom" end)
        end
      end

      assert :open = CircuitBreaker.state(name)
    end
  end

  describe "reset/1" do
    test "clears failures and closes the circuit", %{name: name} do
      for _ <- 1..3, do: CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      assert :open = CircuitBreaker.state(name)

      assert :ok = CircuitBreaker.reset(name)
      assert :closed = CircuitBreaker.state(name)
    end
  end

  describe "snapshot/0" do
    test "includes registered breakers with their state", %{name: name} do
      CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
      snap = CircuitBreaker.snapshot()

      assert %{state: :closed, failures: 1} = snap[name]
    end
  end

  describe "telemetry" do
    test "emits :open and :close events", %{name: name} do
      ref = make_ref()
      handler_id = "cb-test-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:burble, :circuit_breaker, :open],
          [:burble, :circuit_breaker, :close]
        ],
        fn event, measurements, meta, parent ->
          send(parent, {:cb_event, event, measurements, meta})
        end,
        self()
      )

      try do
        for _ <- 1..3, do: CircuitBreaker.with_breaker(name, fn -> {:error, :boom} end)
        assert_receive {:cb_event, [:burble, :circuit_breaker, :open], _, %{name: ^name}}, 100

        Process.sleep(60)
        CircuitBreaker.with_breaker(name, fn -> {:ok, :ok} end)
        assert_receive {:cb_event, [:burble, :circuit_breaker, :close], _, %{name: ^name}}, 100
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
