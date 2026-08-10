# LED output contract

This contract defines the platform-independent interface implemented by the
macOS and Linux GeorgeLight adapters.

## States

| LightState | Device behavior |
| --- | --- |
| `working` | Display the configured working effect and refresh its lease. |
| `actionRequired` | Display the configured attention effect and refresh its lease. |
| `error` | Display the configured error effect. |
| `done` | Display the configured completion effect. |
| `idle` | Clear the display. |

## HTTP interface

Implementations use HTTP and accept a base URL containing only a host and an
optional port.

- Non-idle states send `POST /api/v1/codex/display` with JSON fields `color`,
  `mode_id`, `duration_sec`, and `brightness`.
- Idle sends `POST /api/v1/codex/clear` with an empty body.
- A successful response has an HTTP status in the `200...299` range.

## Delivery behavior

- Only the latest requested state or configuration generation may update the
  adapter's delivery state.
- Failed active-state requests retry with delays of 2, 5, 10, 30, and 60
  seconds, capped at 60 seconds.
- Working and action-required effects refresh every 240 seconds.
- Disabling output attempts one best-effort clear without retrying it.
