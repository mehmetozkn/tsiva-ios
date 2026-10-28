# Changelog

## 0.1.0 (2026-10-28)

First development release.

- `Tsiva.configure` / `Tsiva.track` / `Tsiva.flush` public API
- Event model with install-scoped anonymous ID, session ID and device/app context
- JSON batch upload to `POST /v1/events` over `URLSession`
- In-memory queue with batching, periodic and background flush, retry with exponential backoff and `Retry-After` support
- Sensitive property filtering, `beforeSend` hook, configurable logging
- Privacy manifest (`PrivacyInfo.xcprivacy`)
