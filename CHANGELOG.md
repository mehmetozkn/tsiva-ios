# Changelog

## 0.3.1 (2026-10-29)

- `identify` sends a reserved `$identify` event when the user id changes, so the backend links the install to
  the user immediately, including when no other event follows

## 0.3.0 (2026-10-29)

- `Tsiva.identify(userId:)` attaches your own user identifier to every following event and crash report, and
  remembers it across launches; `Tsiva.reset()` forgets it and starts a new anonymous identity
- Events and crash reports carry `user_id` when set

## 0.2.0 (2026-10-29)

- Crash reporting: fatal signals (SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP, including Swift runtime
  traps such as force-unwrapping `nil`) and uncaught Objective-C exceptions are recorded and sent to
  `POST /v1/crashes` on the next launch. Enabled by default; turn off with `crashReportingEnabled: false`
- Reports include the crashed thread's stack with binary names, offsets and UUIDs for symbolication
- Privacy manifest declares crash data

## 0.1.1 (2026-10-28)

- Released under the MIT License

## 0.1.0 (2026-10-28)

First development release.

- `Tsiva.configure` / `Tsiva.track` / `Tsiva.flush` public API
- Event model with install-scoped anonymous ID, session ID and device/app context
- JSON batch upload to `POST /v1/events` over `URLSession`
- In-memory queue with batching, periodic and background flush, retry with exponential backoff and `Retry-After` support
- Sensitive property filtering, `beforeSend` hook, configurable logging
- Privacy manifest (`PrivacyInfo.xcprivacy`)
