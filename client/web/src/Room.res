// SPDX-License-Identifier: MPL-2.0
//
// Room.res — Room utilities (name generation, validation).

let word_list = [
  "apple", "banana", "cat", "dog", "elephant", "fish", "garden", "house",
  "igloo", "jungle", "kite", "lemon", "mountain", "notebook", "orange",
  "pencil", "queen", "river", "sun", "tree", "umbrella", "violin",
  "water", "xylophone", "yellow", "zebra", "book", "chair", "desk",
  "door", "floor", "glass", "hand", "island", "jacket", "kitchen",
  "lamp", "mirror", "nest", "ocean", "paper", "quilt", "radio",
  "shoe", "table", "violin", "window", "yard", "zero"
]

let pickRandomWord = () => {
  let idx = Math.floor(Math.random() *. Int.toFloat(Array.length(word_list)))
  Array.getUnsafe(word_list, Float.toInt(idx))
}

let generateRoomName = () => {
  pickRandomWord() ++ "-" ++ pickRandomWord() ++ "-" ++ pickRandomWord()
}

let isValidRoomName = (name) => {
  let re = %re("/^[a-z]+-[a-z]+-[a-z]+$/")
  re->RegExp.test(name)
}
