// SPDX-License-Identifier: MPL-2.0
//
// Bindings — Generic JS/DOM bindings for Burble.

type element
type window
type document

@val external window: window = "window"
@val external document: document = "document"

@send external getElementById: (document, string) => element = "getElementById"
@send external createElement: (document, string) => element = "createElement"
@send external appendChild: (element, element) => unit = "appendChild"
@set external setInnerHtml: (element, string) => unit = "innerHTML"
@set external setClassName: (element, string) => unit = "className"
@set external setTextContent: (element, string) => unit = "textContent"
@set external setOnclick: (element, 'ev => unit) => unit = "onclick"

@val external localStorage: {..} = "localStorage"
