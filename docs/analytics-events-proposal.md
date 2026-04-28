# Analytics Event Proposal

Status: first-cut partially implemented.

Use the event numbers below when deciding what to keep, rename, or drop.

## Principles

- PostHog owns product analytics and optional replay.
- Sentry owns crashes and handled/unhandled exceptions.
- Events should be sparse, high-signal, and privacy-aware.
- If `Share diagnostics and analytics` is off, none of these should be sent.

## Currently Instrumented

- 1 `app_opened`
- 2 `pairing_code_submitted`
- 3 `pairing_started`
- 4 `pairing_completed`
- 5 `pairing_failed`
- 8 `message_sent_text`
- 9 `message_sent_image`
- 10 `message_sent_audio`
- 11 `voice_recording_started`
- 12 `voice_recording_finished`
- 13 `voice_recording_failed`
- 14 `settings_opened`
- 15 `telemetry_preference_changed`
- 16 `action_button_recording_triggered`
- 18 `add_device_flow_started`

## Still Proposed, Not Instrumented Yet

- 6 `relay_connected`
- 7 `relay_disconnected`

## Proposed Events

1. `app_opened`
- When: app becomes active from a cold or warm launch
- Properties:
  - `build_channel` (`dev`, `production`)
  - `distribution_channel` (`development`, `app_store`, `simulator`)
  - `app_version`
  - `build_number`

2. `pairing_code_submitted`
- When: user submits a pairing code or URI
- Properties:
  - `input_type` (`code`, `uri`, `direct_config`)

3. `pairing_started`
- When: pairing flow begins successfully
- Properties:
  - `flow` (`join`, `hosted_add_device`)

4. `pairing_completed`
- When: pairing flow completes successfully
- Properties:
  - `flow` (`join`, `hosted_add_device`)

5. `pairing_failed`
- When: pairing exits with an error
- Properties:
  - `flow`
  - `reason`

6. `relay_connected`
- When: websocket handshake completes
- Properties:
  - `relay_host`

7. `relay_disconnected`
- When: relay connection drops
- Properties:
  - `reason`

8. `message_sent_text`
- When: user sends a text message
- Properties:
  - `source` (`keyboard`, `action_button`, `shortcut`)
  - `length_bucket` (`1_20`, `21_80`, `81_300`, `301_plus`)

9. `message_sent_image`
- When: user sends an image
- Properties:
  - `source` (`camera`, `library`)
  - `count`

10. `message_sent_audio`
- When: user sends a voice note
- Properties:
  - `duration_bucket` (`0_15s`, `16_30s`, `31_60s`, `60s_plus`)
  - `source` (`input_bar`, `action_button`)

11. `voice_recording_started`
- When: microphone capture starts
- Properties:
  - `source` (`input_bar`, `action_button`, `shortcut`, `launch_action`)

12. `voice_recording_finished`
- When: microphone capture completes successfully
- Properties:
  - `source`
  - `duration_bucket`

13. `voice_recording_failed`
- When: microphone capture fails
- Properties:
  - `reason`

14. `settings_opened`
- When: settings sheet opens
- Properties: none

15. `telemetry_preference_changed`
- When: `Share diagnostics and analytics` is toggled
- Properties:
  - `enabled`

16. `action_button_recording_triggered`
- When: the app receives the Start Recording shortcut/action successfully
- Properties:
  - `entry` (`shortcut`, `url_handoff`, `foreground_continue`)

17. `history_cleared`
- When: chat history is cleared from settings
- Properties: none

18. `add_device_flow_started`
- When: user taps `Add Device`
- Properties: none

## Suggested First Cut

If we want a conservative first version, I’d start with only:

- 1 `app_opened`
- 4 `pairing_completed`
- 5 `pairing_failed`
- 8 `message_sent_text`
- 9 `message_sent_image`
- 10 `message_sent_audio`
- 11 `voice_recording_started`
- 12 `voice_recording_finished`
- 13 `voice_recording_failed`
- 15 `telemetry_preference_changed`

## Suggested Exclusions

I would avoid for now:

- Per-keystroke or partial-text events
- Typing indicators
- Message bodies or transcript content
- Raw image/audio metadata beyond broad buckets
- Anything tied to hidden QA crash/test gestures
