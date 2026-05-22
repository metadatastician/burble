// SPDX-License-Identifier: MPL-2.0
//
// Audio.res — Microphone and audio analysis helper.

open WebRTC

module Context = {
  type ctx
  type analyser
  type source
  @new external create: unit => ctx = "AudioContext"
  @send external createMediaStreamSource: (ctx, RTC.stream) => source = "createMediaStreamSource"
  @send external createAnalyser: ctx => analyser = "createAnalyser"
  @set external setFftSize: (analyser, int) => unit = "fftSize"
  @get external getFrequencyBinCount: analyser => int = "frequencyBinCount"
  @send external connect: (source, analyser) => unit = "connect"
  @send external getByteFrequencyData: (analyser, Js.Typed_array.Uint8Array.t) => unit = "getByteFrequencyData"
}

type analyzer_state = {
  analyser: Context.analyser,
  data_array: Js.Typed_array.Uint8Array.t,
}

let createAnalyzer = (stream) => {
  let ctx = Context.create()
  let source = ctx->Context.createMediaStreamSource(stream)
  let analyser = ctx->Context.createAnalyser
  analyser->Context.setFftSize(256)
  let _ = source->Context.connect(analyser)
  let count = analyser->Context.getFrequencyBinCount
  let data_array = Js.Typed_array.Uint8Array.fromLength(count)
  {analyser, data_array}
}

let getLevel = (state) => {
  state.analyser->Context.getByteFrequencyData(state.data_array)
  let sum = ref(0)
  for i in 0 to Js.Typed_array.Uint8Array.length(state.data_array) - 1 {
    sum := sum.contents + Js.Typed_array.Uint8Array.unsafe_get(state.data_array, i)
  }
  let avg = Int.toFloat(sum.contents) /. Int.toFloat(Js.Typed_array.Uint8Array.length(state.data_array))
  Math.min(100.0, (avg /. 128.0) *. 100.0)
}
