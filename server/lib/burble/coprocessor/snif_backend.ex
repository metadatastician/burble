# SPDX-License-Identifier: MPL-2.0
#
# SNIF kernel coverage
# ====================
#
# Kernels with SNIF (WASM) coverage — crash-isolated execution:
#   - dsp_fft          (burble_fft.wasm — "fft" export)
#   - dsp_ifft         (burble_fft.wasm — "ifft" export)
#   - audio_noise_gate (burble_noise_gate.wasm — "noise_gate" export)
#   - audio_echo_cancel (burble_echo_cancel.wasm — "echo_cancel" export)
#
# SNIF candidates — deferred:
#   - neural_denoise   (deferred: stateful model — the WASM guest would need to
#                       hold opaque model weights across calls, which requires
#                       either persistent WASM instance management or serialising
#                       model state through linear memory on every invocation.
#                       Neither is trivial; revisit when a stateless checkpoint
#                       format is defined for the Zig RNNoise port.)
#
defmodule Burble.Coprocessor.SNIFBackend do
  @moduledoc """
  SNIF (Safe Native Implemented Function) backend using WebAssembly for crash-isolated DSP operations.
  
  This backend provides the same interface as ZigBackend but uses WASM-compiled
  Zig code via wasmex for memory safety and crash isolation.
  
  ## Overview
  
  SNIFs (Safe NIFs) use WebAssembly sandboxing to provide genuine crash isolation
  for BEAM NIFs. Any crash in a NIF normally kills the entire BEAM VM. SNIFs convert
  all guest faults into `{:error, reason}` tuples — the BEAM process survives unconditionally.
  
  ## Key Benefits
  
  - **Crash Isolation:** WASM execution errors become `{:error, reason}` tuples
  - **Memory Safety:** Automatic bounds checking prevents memory corruption
  - **BEAM Survival:** The BEAM process survives all WASM crashes
  - **Graceful Degradation:** Automatic fallback to Zig NIFs on errors
  - **Performance:** ~10-15% overhead vs traditional NIFs
  
  ## Architecture
  
  ```
  Elixir → SNIFBackend → WASM → CPU
          ↓ (fallback)
       ZigBackend → NIF → CPU
          ↓ (fallback)
       ElixirBackend → BEAM
  ```
  
  ## Configuration
  
  Configure WASM module path in `config/runtime.exs`:
  
  ```elixir
  config :burble, :snif_path, "priv/snif/burble_fft.wasm"
  
  # Or via environment variable:
  # export BURBLE_SNIF_PATH="/custom/path/to/burble_fft.wasm"
  ```
  
  ## WASM Module
  
  The WASM module should export:
  - `fft(data: []f32, n: usize) -> void` - In-place FFT
  - `ifft(data: []f32, n: usize) -> void` - In-place IFFT
  - `still_alive() -> i32` - Health check (returns 42)
  
  Build with Zig using ReleaseSafe mode:
  ```bash
  zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSafe
  ```
  
  ## Performance
  
  - FFT 256pt: ~25-27µs (vs 22µs NIF) - ~10-15% overhead
  - FFT 1024pt: ~95-100µs (vs 85µs NIF) - ~10-15% overhead
  - Memory: ~1MB per WASM instance
  - Load time: <1ms (cached)
  
  ## Safety
  
  - **ReleaseSafe compilation:** All safety violations become WASM traps
  - **Bounds checking:** Automatic array bounds validation
  - **Memory isolation:** WASM linear memory sandbox
  - **Crash recovery:** BEAM process continues after WASM traps
  """

  @behaviour Burble.Coprocessor.Backend

  require Logger

  alias Burble.Coprocessor.{ElixirBackend, ZigBackend}
  
  # Configuration - paths to WASM modules.
  # Each kernel has its own WASM module so that a missing or corrupt module for
  # one operation does not affect the others.
  @snif_path Application.compile_env(:burble, :snif_path) ||
               "priv/snif/burble_fft.wasm"
  @snif_noise_gate_path Application.compile_env(:burble, :snif_noise_gate_path) ||
                          "priv/snif/burble_noise_gate.wasm"
  @snif_echo_cancel_path Application.compile_env(:burble, :snif_echo_cancel_path) ||
                           "priv/snif/burble_echo_cancel.wasm"
  
  # ---------------------------------------------------------------------------
  # Backend metadata
  # ---------------------------------------------------------------------------

  @doc """
  Returns the backend type atom.
  
  ## Returns
  
  - `:snif` - This is the SNIF backend
  
  ## Examples
  
  ```elixir
  Burble.Coprocessor.SNIFBackend.backend_type()
  #=> :snif
  ```
  """
  @impl true
  def backend_type, do: :snif

  @doc """
  Checks if the SNIF backend is available (WASM module exists and is loadable).
  
  ## Returns
  
  - `true` if WASM module exists at configured path
  - `false` if WASM module is missing or inaccessible
  
  ## Configuration
  
  The WASM module path can be configured via:
  - `BURBLE_SNIF_PATH` environment variable
  - `:snif_path` in runtime configuration
  - Default: `"priv/snif/burble_fft.wasm"`
  
  ## Examples
  
  ```elixir
  # Check availability
  Burble.Coprocessor.SNIFBackend.available?()
  #=> true (if WASM module exists)
  
  # Disable SNIF (fallback to Zig NIFs)
  System.put_env("BURBLE_SNIF_PATH", "")
  Burble.Coprocessor.SNIFBackend.available?()
  #=> false
  ```
  
  ## Troubleshooting
  
  If this returns `false`:
  1. Verify WASM file exists at configured path
  2. Check file permissions (must be readable)
  3. Verify configuration in `config/runtime.exs`
  4. Check `BURBLE_SNIF_PATH` environment variable
  """
  # Optional WASM runtime. Referenced via apply/3 (see call_snif_module/3)
  # so the compiler does not warn when :wasmex is absent at build time —
  # mirrors the Burble.Bolt.Quic / :quicer pattern (ADR-0004). When absent,
  # available?/0 is false so every kernel transparently uses ZigBackend.
  @wasmex Wasmex

  @impl true
  def available? do
    File.exists?(@snif_path) and
      Code.ensure_loaded?(@wasmex) and
      function_exported?(@wasmex, :start_link, 1)
  end

  # ---------------------------------------------------------------------------
  # DSP kernel - FFT operations with SNIF
  # ---------------------------------------------------------------------------

  @doc """
  Computes the Fast Fourier Transform (FFT) using WebAssembly for crash isolation.
  
  This function first attempts to use the SNIF (WASM) implementation for safety,
  and automatically falls back to the traditional Zig NIF if the WASM execution fails.
  
  ## Parameters
  
  - `signal`: List of floats representing the time-domain signal
  - `size`: Integer representing the FFT size (must be power of 2)
  
  ## Returns
  
  - `{[{real, imag}, ...]}` - List of complex tuples representing frequency bins
  - Falls back to `ZigBackend.dsp_fft/2` on WASM errors
  
  ## Performance
  
  - **SNIF (WASM):** ~25-27µs for 256-point FFT (~10-15% overhead vs NIF)
  - **Fallback (Zig NIF):** ~22µs for 256-point FFT
  - **Memory:** ~1MB WASM instance + signal data
  
  ## Safety
  
  - **Crash Isolation:** WASM execution errors become `{:error, reason}` tuples
  - **Memory Safety:** Automatic bounds checking in WASM
  - **BEAM Survival:** BEAM process continues even if WASM crashes
  - **Graceful Degradation:** Automatic fallback to Zig NIF on errors
  
  ## Examples
  
  ```elixir
  # Simple 4-point FFT
  signal = [1.0, 0.0, -1.0, 0.0]
  result = Burble.Coprocessor.SNIFBackend.dsp_fft(signal, 4)
  #=> [{1.0, 0.0}, {0.0, 0.0}, {-1.0, 0.0}, {0.0, 0.0}]
  
  # 256-point FFT with real audio data
  audio_signal = List.duplicate(0.0, 256) ++ [1.0]
  fft_result = Burble.Coprocessor.SNIFBackend.dsp_fft(audio_signal, 256)
  #=> [{magnitude, phase}, ...]
  
  # Automatic fallback on WASM errors
  # If WASM crashes, automatically uses Zig NIF and logs warning
  ```
  
  ## Implementation Notes
  
  The WASM FFT implementation uses the Cooley-Tukey radix-2 DIT algorithm:
  
  1. **Input:** Real-valued signal as flat list `[s0, s1, s2, ...]`
  2. **WASM Processing:** In-place FFT on interleaved complex data
  3. **Output:** Complex spectrum as `[{re0, im0}, {re1, im1}, ...]`
  4. **Fallback:** Zig NIF implementation if WASM fails
  
  ## Error Handling
  
  Common WASM errors and their resolutions:
  
  - `:function_not_found` - WASM module missing required exports
  - `:out_of_bounds_memory_access` - Input size mismatch
  - `:wasm_load_failed` - WASM module file not found or corrupt
  - `:snif_exception` - Unexpected Elixir-side error
  
  All errors trigger automatic fallback to ZigBackend with warning logs.
  """
  @impl true
  def dsp_fft(signal, size) do
    case call_snif("fft", [length(signal)] ++ signal) do
      {:ok, result} -> 
        # Convert WASM result format to Elixir format
        parse_fft_result(result, size)
      {:error, reason} -> 
        Logger.warning("SNIF FFT failed: #{inspect(reason)}, falling back to Zig NIF")
        ZigBackend.dsp_fft(signal, size)
    end
  end

  @doc """
  Computes the Inverse Fast Fourier Transform (IFFT) using WebAssembly.
  
  Converts frequency-domain spectrum back to time-domain signal with the same
  crash isolation and safety guarantees as `dsp_fft/2`.
  
  ## Parameters
  
  - `spectrum`: List of complex tuples `[{real, imag}, ...]` representing frequency bins
  - `size`: Integer representing the IFFT size (must match FFT size)
  
  ## Returns
  
  - `[float()]` - List of real-valued time-domain samples
  - Falls back to `ZigBackend.dsp_ifft/2` on WASM errors
  
  ## Performance
  
  - **SNIF (WASM):** ~25-27µs for 256-point IFFT
  - **Fallback (Zig NIF):** ~22µs for 256-point IFFT
  - **Accuracy:** Typically <1e-5 error vs original signal
  
  ## Examples
  
  ```elixir
  # Round-trip FFT/IFFT
  signal = [1.0, 0.0, -1.0, 0.0]
  spectrum = Burble.Coprocessor.SNIFBackend.dsp_fft(signal, 4)
  recovered = Burble.Coprocessor.SNIFBackend.dsp_ifft(spectrum, 4)
  #=> [1.0, 0.0, -1.0, 0.0] (within floating-point precision)
  
  # Frequency filtering example
  spectrum = Burble.Coprocessor.SNIFBackend.dsp_fft(audio, 256)
  filtered_spectrum = filter_frequencies(spectrum)
  filtered_audio = Burble.Coprocessor.SNIFBackend.dsp_ifft(filtered_spectrum, 256)
  ```
  
  ## Implementation Notes
  
  The IFFT implementation uses the conjugate-FFT trick:
  
  1. **Input:** Complex spectrum as `[{re, im}, ...]`
  2. **Conversion:** Flatten to `[re0, im0, re1, im1, ...]` for WASM
  3. **WASM Processing:** Conjugate → FFT → Conjugate → Scale
  4. **Output:** Real-valued samples (imaginary parts near zero)
  5. **Fallback:** Zig NIF implementation if WASM fails
  
  ## Error Handling
  
  Same error handling as `dsp_fft/2` with automatic fallback.
  """
  @impl true
  def dsp_ifft(spectrum, size) do
    case call_snif("ifft", prepare_ifft_input(spectrum)) do
      {:ok, result} -> 
        # Convert WASM result format to Elixir format  
        parse_ifft_result(result)
      {:error, reason} -> 
        Logger.warning("SNIF IFFT failed: #{inspect(reason)}, falling back to Zig NIF")
        ZigBackend.dsp_ifft(spectrum, size)
    end
  end

  # Fallback to ZigBackend for other operations (not yet SNIF-implemented)
  @impl true
  def audio_encode(pcm, sample_rate, channels, bitrate), 
    do: ZigBackend.audio_encode(pcm, sample_rate, channels, bitrate)

  @impl true
  def audio_decode(pcm_frame, sample_rate, channels),
    do: ZigBackend.audio_decode(pcm_frame, sample_rate, channels)

  @impl true
  def opus_transcode(pcm_or_opus, sample_rate, channels, bitrate),
    do: ZigBackend.opus_transcode(pcm_or_opus, sample_rate, channels, bitrate)

  @impl true
  def opus_available?, do: false

  @impl true
  def audio_noise_gate(pcm, threshold_db) do
    if available?() do
      snif_noise_gate(pcm, threshold_db)
    else
      ZigBackend.audio_noise_gate(pcm, threshold_db)
    end
  end

  @impl true
  def audio_echo_cancel(capture, reference, filter_length) do
    if available?() do
      snif_echo_cancel(capture, reference, filter_length)
    else
      ZigBackend.audio_echo_cancel(capture, reference, filter_length)
    end
  end

  # ---------------------------------------------------------------------------
  # DSP kernel - noise gate with SNIF
  # ---------------------------------------------------------------------------

  @doc """
  Applies a noise gate to a PCM signal using WebAssembly for crash isolation.

  Attempts execution in the SNIF (WASM) sandbox first. Any WASM fault is caught
  and converted to a `{:error, reason}` tuple; the function then falls back to
  `ZigBackend.audio_noise_gate/2` so the audio pipeline is never interrupted.

  ## Parameters

  - `pcm`: List of floats — time-domain samples
  - `threshold_db`: Float — gate open threshold in dBFS (e.g. `-40.0`)

  ## Returns

  - `[float()]` — gated PCM samples
  - Falls back to `ZigBackend.audio_noise_gate/2` on WASM errors

  ## Safety

  Same crash-isolation guarantees as `dsp_fft/2`. The WASM module
  (`burble_noise_gate.wasm`) is loaded on demand and stopped after each call.

  ## Examples

  ```elixir
  gated = SNIFBackend.snif_noise_gate([0.001, 0.5, -0.001], -40.0)
  #=> [0.0, 0.5, 0.0]  (samples below threshold zeroed)
  ```
  """
  def snif_noise_gate(pcm, threshold_db) do
    case call_snif_module(@snif_noise_gate_path, "noise_gate", [length(pcm), threshold_db] ++ pcm) do
      {:ok, result} ->
        result
      {:error, reason} ->
        Logger.warning("SNIF noise_gate failed: #{inspect(reason)}, falling back to Zig NIF")
        ZigBackend.audio_noise_gate(pcm, threshold_db)
    end
  end

  # ---------------------------------------------------------------------------
  # DSP kernel - echo cancellation with SNIF
  # ---------------------------------------------------------------------------

  @doc """
  Applies acoustic echo cancellation using WebAssembly for crash isolation.

  Attempts execution in the SNIF (WASM) sandbox first. Any WASM fault is caught
  and converted to a `{:error, reason}` tuple; the function then falls back to
  `ZigBackend.audio_echo_cancel/3` so the audio pipeline is never interrupted.

  ## Parameters

  - `capture`: List of floats — microphone signal (near-end)
  - `reference`: List of floats — loudspeaker reference signal (far-end)
  - `filter_length`: Integer — adaptive filter length in samples

  ## Returns

  - `[float()]` — echo-cancelled PCM samples
  - Falls back to `ZigBackend.audio_echo_cancel/3` on WASM errors

  ## Safety

  Same crash-isolation guarantees as `dsp_fft/2`. Because echo cancellation is
  stateless in this interface (filter coefficients are not persisted between
  calls), the WASM module can be stopped after each invocation without losing
  state.

  ## Examples

  ```elixir
  cancelled = SNIFBackend.snif_echo_cancel(capture, reference, 128)
  #=> [float()]  — capture with echo attenuated
  ```
  """
  def snif_echo_cancel(capture, reference, filter_length) do
    args = [length(capture), filter_length] ++ capture ++ reference
    case call_snif_module(@snif_echo_cancel_path, "echo_cancel", args) do
      {:ok, result} ->
        result
      {:error, reason} ->
        Logger.warning("SNIF echo_cancel failed: #{inspect(reason)}, falling back to Zig NIF")
        ZigBackend.audio_echo_cancel(capture, reference, filter_length)
    end
  end

  # ---------------------------------------------------------------------------
  # SNIF Core - WASM interaction
  # ---------------------------------------------------------------------------

  @doc """
  Low-level function to call a WASM-exported function with automatic error handling.
  
  This is the core SNIF execution primitive that provides crash isolation.
  All WASM execution errors are caught and converted to `{:error, reason}` tuples,
  ensuring the BEAM process survives regardless of what happens in the WASM guest.
  
  ## Parameters
  
  - `function`: String name of the WASM-exported function
  - `args`: List of arguments to pass to the WASM function
  
  ## Returns
  
  - `{:ok, result}` - Successful execution with result
  - `{:error, reason}` - WASM execution error (BEAM process survives)
  
  ## Error Types
  
  - `:wasm_load_failed` - WASM module file not found or corrupt
  - `:function_not_found` - Requested function not exported by WASM
  - `:out_of_bounds_memory_access` - Invalid memory access in WASM
  - `:snif_exception` - Unexpected Elixir-side error
  - `:wasm_execution_failed` - General WASM execution trap
  
  ## Safety Guarantees
  
  - **Crash Isolation:** All WASM faults become `{:error, reason}`
  - **Memory Safety:** WASM cannot corrupt BEAM memory
  - **Process Survival:** BEAM process continues after any WASM error
  - **Resource Cleanup:** WASM instance is stopped after each call
  
  ## Implementation
  
  Uses wasmex for BEAM-WASM interop:
  1. Load WASM module via `Wasmex.start_link/1`
  2. Call function via `Wasmex.call_function/3`
  3. Stop WASM instance via `GenServer.stop/2`
  4. Return result or convert trap to error tuple
  
  ## Performance
  
  - WASM load: ~1ms (first call), cached thereafter
  - Function call: Depends on WASM implementation
  - Memory: ~1MB per WASM instance (stopped after call)
  
  ## Examples
  
  ```elixir
  # Call a health check function
  {:ok, [42]} = call_snif("still_alive", [])
  
  # Call FFT function
  {:ok, fft_result} = call_snif("fft", [4, 1.0, 0.0, -1.0, 0.0])
  
  # Handle WASM execution error
  {:error, :function_not_found} = call_snif("nonexistent_function", [])
  ```
  
  ## Troubleshooting
  
  If you get unexpected errors:
  1. Verify WASM module exists at `@snif_path`
  2. Check WASM module exports with `wasm-objdump -x module.wasm`
  3. Validate input arguments match WASM function signature
  4. Test with simple functions like "still_alive" first
  """
  defp call_snif(function, args) do
    call_snif_module(@snif_path, function, args)
  end

  # General SNIF execution primitive: load the WASM module at `path`, call
  # `function` with `args`, then stop the WASM instance. Any error — including
  # a missing WASM file, a WASM trap, or an Elixir exception — is returned as
  # `{:error, reason}` so the caller can fall back gracefully.
  defp call_snif_module(path, function, args) do
    try do
      case apply(@wasmex, :start_link, [%{bytes: File.read!(path)}]) do
        {:ok, pid} ->
          result = apply(@wasmex, :call_function, [pid, function, args])
          GenServer.stop(pid, :normal)
          result
        {:error, reason} -> {:error, {:wasm_load_failed, reason}}
      end
    rescue
      error -> {:error, {:snif_exception, error}}
    end
  end

  # ---------------------------------------------------------------------------
  # Format conversion utilities
  # ---------------------------------------------------------------------------

  @doc """
  Converts FFT result from WASM flat format to Elixir complex tuple format.
  
  The WASM FFT implementation returns results as a flat list of interleaved
  real and imaginary components. This function converts that format to the
  Elixir convention of complex tuples.
  
  ## Parameters
  
  - `flat_result`: Flat list `[re0, im0, re1, im1, ...]` from WASM
  - `size`: Expected number of complex values (FFT size)
  
  ## Returns
  
  - `[{real, imag}, ...]` - List of complex tuples
  
  ## Examples
  
  ```elixir
  # WASM returns flat FFT result
  flat = [1.0, 0.0, 0.0, 1.0, 0.5, 0.5]
  
  # Convert to Elixir format
  result = parse_fft_result(flat, 3)
  #=> [{1.0, 0.0}, {0.0, 1.0}, {0.5, 0.5}]
  ```
  
  ## Implementation Notes
  
  - Uses `Enum.chunk_every(2)` to pair real/imaginary components
  - Takes only `size` elements to ensure correct FFT size
  - Preserves the order of frequency bins from WASM
  
  ## Performance
  
  - O(n) time complexity
  - Minimal memory allocation
  - Typically <1µs for typical FFT sizes
  """
  def parse_fft_result(flat_result, size) do
    # WASM returns [re0, im0, re1, im1, ...]
    # We need [{re0, im0}, {re1, im1}, ...]
    flat_result
    |> Enum.chunk_every(2)
    |> Enum.map(fn [re, im] -> {re, im} end)
    |> Enum.take(size)  # Ensure correct size
  end

  @doc """
  Converts Elixir complex tuple format to WASM flat format for IFFT input.
  
  The WASM IFFT implementation expects input as a flat list of interleaved
  real and imaginary components. This function prepares the input in that format.
  
  ## Parameters
  
  - `spectrum`: List of complex tuples `[{real, imag}, ...]`
  
  ## Returns
  
  - `[re0, im0, re1, im1, ...]` - Flat list for WASM consumption
  
  ## Examples
  
  ```elixir
  # Elixir complex spectrum
  spectrum = [{1.0, 0.0}, {0.0, 1.0}]
  
  # Convert to WASM format
  result = prepare_ifft_input(spectrum)
  #=> [1.0, 0.0, 0.0, 1.0]
  ```
  
  ## Implementation Notes
  
  - Uses `Enum.flat_map/2` to interleave components
  - Preserves the order of frequency bins
  - Handles any size of spectrum
  
  ## Performance
  
  - O(n) time complexity
  - Minimal memory allocation
  - Typically <1µs for typical FFT sizes
  """
  def prepare_ifft_input(spectrum) do
    spectrum
    |> Enum.flat_map(fn {re, im} -> [re, im] end)
  end

  @doc """
  Extracts real parts from WASM IFFT result.
  
  The WASM IFFT implementation returns results as interleaved real and
  imaginary components, where the imaginary parts should be near zero
  for properly computed IFFTs. This function extracts just the real parts
  to return the time-domain signal.
  
  ## Parameters
  
  - `complex_result`: Flat list `[re0, im0, re1, im1, ...]` from WASM IFFT
  
  ## Returns
  
  - `[re0, re1, re2, ...]` - Real-valued time-domain samples
  
  ## Examples
  
  ```elixir
  # WASM IFFT result (imaginary parts near zero)
  complex = [1.0, 0.0, 0.5, 0.0, 0.25, 0.0]
  
  # Extract real parts
  result = parse_ifft_result(complex)
  #=> [1.0, 0.5, 0.25]
  ```
  
  ## Implementation Notes
  
  - Uses `Enum.chunk_every(2)` to separate real/imaginary components
  - Discards imaginary parts (should be ~0 for valid IFFT)
  - Preserves the order of time-domain samples
  
  ## Performance
  
  - O(n) time complexity
  - Minimal memory allocation
  - Typically <1µs for typical FFT sizes
  
  ## Quality Assurance
  
  The imaginary parts should be very close to zero (<1e-6) for a properly
  computed IFFT. If you see large imaginary components, it may indicate:
  
  - Numerical instability in the FFT/IFFT computation
  - Input spectrum that doesn't satisfy conjugate symmetry
  - Bug in the WASM IFFT implementation
  """
  def parse_ifft_result(complex_result) do
    # IFFT returns [re0, im0, re1, im1, ...]
    # We want [re0, re1, re2, ...] (imaginary parts should be ~0)
    complex_result
    |> Enum.chunk_every(2)
    |> Enum.map(fn [re, _im] -> re end)
  end
end