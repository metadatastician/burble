// SPDX-License-Identifier: MPL-2.0
//
// Main — Entry point for the Burble web client.
//
// Initialises the application state, sets up routing, and
// starts the render loop.

// Initialise application
let app = App.make()

// Log startup
Console.log("[Burble] Web client initialised")
Console.log2("[Burble] Route:", Routes.toString(app.currentRoute))
Console.log2("[Burble] Auth:", AuthState.displayName(app.auth))

// Listen for browser back/forward navigation
@val @scope("window")
external addPopStateListener: (@as("popstate") _, 'a => unit) => unit = "addEventListener"

addPopStateListener(_ => {
  let path: string = %raw(`window.location.pathname`)
  App.handleUrlChange(app, path)
})

// Set initial page title
let _ = {
  let title = Routes.title(app.currentRoute)
  let _ = %raw(`(t => { document.title = t })`)(title)
}

Console.log("[Burble] Voice first. Friction last. Complexity optional.")
