# Tsiva iOS SDK

Lightweight event tracking for iOS apps. Tsiva batches the events your app records and sends them to your
Tsiva backend. It has no third-party dependencies.

- iOS 15+ (macOS 12+ is also supported, mainly for running the tests)
- Swift 6, thread-safe, never crashes or blocks the host app
- Batched uploads with retry and exponential backoff
- Built-in filtering of sensitive properties

> **Status:** `0.1.0`, an early development release. The public API may still change before `1.0`.

## Installation

### Xcode

**File › Add Package Dependencies…**, enter the repository URL and add the `Tsiva` library to your app target:

```
https://github.com/mehmetozkn/tsiva-ios
```

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/mehmetozkn/tsiva-ios", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Tsiva", package: "tsiva-ios")])
]
```

## Usage

Configure the SDK once, as early as possible in the app's life:

```swift
import SwiftUI
import Tsiva

@main
struct MyApp: App {
    init() {
        Tsiva.configure(
            apiKey: "YOUR_PROJECT_KEY",
            endpoint: URL(string: "https://your-tsiva-api.example.com")!
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Then record events anywhere, from any thread:

```swift
Tsiva.track("app_opened")

Tsiva.track("checkout_started", properties: [
    "payment_method": "card",
    "item_count": 3,
    "total": 49.90,
    "is_first_order": true
])
```

Property values can be strings, integers, doubles or booleans. Events are uploaded automatically: when 20 events
are queued, every 30 seconds, and when the app moves to the background. To send immediately (for example
before a test run finishes), call:

```swift
await Tsiva.flush()
```

## Configuration

```swift
Tsiva.configure(TsivaConfiguration(
    apiKey: "YOUR_PROJECT_KEY",
    endpoint: URL(string: "https://your-tsiva-api.example.com")!,
    flushAt: 20,            // events per batch; also triggers an upload
    flushInterval: 30,      // seconds between periodic uploads
    maxQueueSize: 1000,     // oldest events are dropped beyond this
    maxRetries: 3,          // retries for network errors, 429 and 5xx
    logLevel: .debug,       // .none, .error (default), .warning, .debug
    beforeSend: { event in
        var event = event
        event.properties["environment"] = "staging"
        return event        // return nil to drop the event
    }
))
```

`configure` should be called only once. Later calls are ignored and a warning is logged.

## Privacy

- **Sensitive keys are removed** before an event is queued. By default, any property whose key contains
  `password`, `secret`, `token`, `apikey`, `authorization`, `cookie`, `creditcard`, `cardnumber`, `cvv`, `cvc`,
  `iban`, `ssn`, `email` or `phone` is dropped. Matching ignores case, `_`, `-` and spaces. You can customise
  the list with `redactedPropertyKeys`, and `beforeSend` gives you full control over each event.
- **No device identifiers** are collected. Each install gets a random `anonymousId` that is reset when the app
  is reinstalled. Tsiva does not use IDFA or IDFV, and does not require App Tracking Transparency.
- **Collected context:** SDK version, app bundle ID/version/build, OS name/version, hardware model
  (e.g. `iPhone16,2`), locale and time zone.
- Events are kept **in memory only**. Events that have not been uploaded yet are lost if the app is
  terminated.

Do not put personal data such as names, emails or free-form user input into event properties.

## Security

The API key is embedded in your app and can be extracted from the binary. Treat it as a **project
identifier, not a secret**: it can only submit events. The backend enforces rate limits, quotas and payload
validation.

## Backend contract

The request format and the retry semantics are documented in [docs/event-schema.md](docs/event-schema.md).

## Development

```bash
swift build
swift test                                    # runs on macOS, no simulator needed
xcodebuild test -scheme Tsiva -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Roadmap

Crash reporting, automatic HTTP instrumentation, performance monitoring and a persistent (on-disk) queue are
planned for later releases.
