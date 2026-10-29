# Event Ingestion Contract (v1)

This is the wire format the iOS SDK sends. The Tsiva backend's `POST /v1/events` endpoint must accept it.

## Request

```
POST {endpoint}/v1/events
Content-Type: application/json
X-Tsiva-Api-Key: <project key>
User-Agent: tsiva-ios/0.1.0
```

The API key identifies the project. It ships inside the app binary and is **not a secret**: the backend must
apply rate limits, quotas and payload validation per key, and must never grant read access with it.

## Body

```json
{
  "sent_at": "2026-10-28T18:30:18.449Z",
  "events": [
    {
      "id": "CA111367-11F5-4DD1-AC1D-3B860C9B3B12",
      "name": "checkout_started",
      "timestamp": "2026-10-28T18:30:17.902Z",
      "properties": { "payment_method": "card", "item_count": 3 },
      "anonymous_id": "AB543922-05B7-4C76-97BB-9F7B9741A03E",
      "session_id": "B6D0D173-8604-483A-8179-53406E9F951D",
      "context": {
        "sdk": { "name": "tsiva-ios", "version": "0.1.0" },
        "app": { "bundle_id": "com.example.app", "version": "1.2.0", "build": "42" },
        "os": { "name": "iOS", "version": "18.0.0" },
        "device": { "model": "iPhone16,2" },
        "locale": "tr_TR",
        "timezone": "Europe/Istanbul"
      }
    }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `sent_at` | string | Device time when the request was built. Compare with `timestamp` to correct device clock skew. |
| `events` | array | 1 to 100 events. |
| `id` | string (UUID) | Unique per event. Retries resend the same `id`, so the backend should **deduplicate on it**. |
| `name` | string | 1 to 128 characters. |
| `timestamp` | string | Device time when `track` was called. |
| `properties` | object | Up to 100 keys (max 128 characters each). Values are string (max 1024 characters), integer, number or boolean. |
| `anonymous_id` | string | Random per-install ID, persisted on the device. Not derived from IDFA/IDFV. |
| `session_id` | string | New on every app launch (every `Tsiva.configure`). |
| `context.app.*` | string | Every field is optional and is omitted when unavailable. |

All timestamps are ISO 8601, UTC, millisecond precision.

## Responses the SDK understands

| Status | SDK behaviour |
|---|---|
| `2xx` | Success, batch removed from the queue. `202 Accepted` is recommended. |
| `408`, `429`, `5xx`, network error | Batch kept and retried with exponential backoff (2s, 4s, 8s, ... max 5 min). A `Retry-After` header in seconds is honoured. Dropped after `maxRetries` retries (default 3). |
| any other `4xx` | Batch dropped immediately, without retrying. Use `400` for an invalid payload, `401` for an unknown key and `413` for an oversized body. |

The response body is ignored.

## Crash reports: `POST {endpoint}/v1/crashes`

Same headers as `/v1/events`. One report per request, sent on the launch after the crash.

```json
{
  "id": "4F1A6C2E-6B8D-4C55-9E0B-6A1F7B3D2C11",
  "timestamp": "2026-10-29T09:27:15.000Z",
  "kind": "signal",
  "signal": { "number": 11, "name": "SIGSEGV", "code": 1, "fault_address": "0x8" },
  "exception": null,
  "frames": [
    { "address": "0x100004280", "image": "MyApp", "offset": 17024, "in_app": true },
    { "address": "0x18b2c1234", "image": "libdyld.dylib", "offset": 4660, "in_app": false }
  ],
  "images": [
    { "name": "MyApp", "uuid": "1F2E3D4C-5B6A-7980-1A2B-3C4D5E6F7A8B", "load_address": "0x100000000", "size": 65536 }
  ],
  "anonymous_id": "AB543922-05B7-4C76-97BB-9F7B9741A03E",
  "session_id": "B6D0D173-8604-483A-8179-53406E9F951D",
  "context": { "sdk": { "name": "tsiva-ios", "version": "0.2.0" }, "app": { "version": "1.2.0" }, "os": { "name": "iOS", "version": "26.0" }, "device": { "model": "iPhone16,2" }, "locale": "tr_TR", "timezone": "Europe/Istanbul" }
}
```

| Field | Notes |
|---|---|
| `kind` | `signal` (with `signal`) or `exception` (with `exception: {name, reason}`). |
| `frames` | The crashed thread's stack, innermost first, at most 100. `image`/`offset` are missing when the address is in no known binary. `in_app` marks the app's own executable. |
| `images` | Only the binaries that appear in `frames`. With `uuid` and `load_address`, a frame can be symbolicated using the app's dSYM. |
| `anonymous_id`, `session_id`, `context` | From the session that crashed, not the one that sends the report. |

Responses follow the same rules as `/v1/events`: `2xx` deletes the report, `4xx` drops it, `429`/`5xx`/network
errors keep it for the next launch. Retries resend the same `id`, so the backend must deduplicate on it.
