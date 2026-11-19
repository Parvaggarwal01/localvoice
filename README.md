# LocalVoice

LocalVoice is a lightweight, native macOS dictation app. Press **Fn** to start or stop recording, then the app transcribes the saved audio with Deepgram, copies the result, and can optionally send **⌘V** to the focused app.

## Requirements

- macOS 13 or later
- Apple silicon Mac (the build currently targets `arm64`)
- Xcode Command Line Tools, including Swift, `codesign`, and `openssl`
- A Deepgram API key for transcription

## Install from source

This repository is private. You need collaborator access to clone it or download its source archive.

```sh
git clone https://github.com/kartik-py12/LocalVoice.git
cd LocalVoice
./Scripts/setup-signing.sh
./Scripts/build-app.sh
```

Run `setup-signing.sh` once on each Mac. It creates a local signing identity in that Mac's login Keychain. Then `build-app.sh` compiles the app, installs it at `~/Applications/LocalVoice.app`, and opens it. For later updates, pull the latest code and rerun `./Scripts/build-app.sh`; it reuses the signing identity, restarts an idle app, and refuses to update while an audio file is open.

## First-run setup

1. Open **Settings** in LocalVoice, enter your Deepgram API key, and save it. The app stores it in macOS Keychain; no API key belongs in this repository.
2. Enable **Fn shortcut**. In **System Settings → Privacy & Security → Input Monitoring**, allow `LocalVoice` from `~/Applications/LocalVoice.app` if macOS asks.
3. Allow microphone access when prompted the first time you record.
4. Optional: enable **Auto-paste transcripts**. This sends ⌘V without pressing Return and requires the separate **Accessibility** permission for LocalVoice.

## Use

- Press **Fn** once to start recording and again to stop and transcribe.
- Or use the recording button in the app or its recording HUD.
- Successful transcripts are copied to the clipboard. With auto-paste on, LocalVoice sends ⌘V to the external app that remains focused after transcription.
- Open **History** to review transcripts and play or locate saved recordings. Delete a history item to remove its transcript and audio file.

Audio and transcript history stay under `~/Library/Application Support/LocalVoice/`. Audio is uploaded to Deepgram over HTTPS when transcription is requested. LocalVoice uses Deepgram Nova-3 multilingual mode with smart formatting and punctuation.

## Meetings

Meetings mode records a whole call (your microphone **and** the other participants), transcribes it with Deepgram, and posts the transcript to Slack for Helm. Fn dictation is unchanged and keeps its own HUD.

### What it does

- **Calendar:** reads the calendars already added to macOS Calendar (Google accounts included) with EventKit. Every 15 minutes, on launch and whenever a calendar changes, it posts this Mac's agenda for the next 36 hours to `#meetings-sync`. It keeps one message per Mac and edits it in place. All-day and declined events are left out.
- **Prompts:** from 1 minute before a calendar event starts, a small card asks *Record <title>?* (Start / Not now). The same card appears when Zoom, Microsoft Teams, Slack (huddle), Webex, FaceTime or a browser call (Google Meet) starts using the microphone. A notification also arrives a few minutes before each event (5 by default). You can always start manually from the **Meetings** tab.
- **Recording:** the microphone is saved as "Me" and the system audio (ScreenCaptureKit) as "others", each written to disk while the meeting runs, so hour-long meetings are fine. A 56 px red circle floats on top: it pulses with the audio, shows elapsed time on hover, can be dragged, and stops the recording when clicked. When the calendar event has ended and the call app releases the microphone, LocalVoice offers to stop.
- **Transcript:** the two tracks are combined into one stereo file (left = me, right = others) and sent to Deepgram Nova-3 with multichannel and speaker diarization, so lines read `Me: …`, `Speaker 1: …`. The transcript is saved as `meeting-<id>.json` and uploaded to `#meetings` in the format Helm expects. Meetings appear in **History** with a two-person icon; a failed step can be retried there, and **Send to Slack** retries the upload.

### Setup (once per Mac)

1. In Slack, create `#meetings` and `#meetings-sync` and invite **@Helm** to both. Copy each channel ID (channel name → *View channel details* → bottom of the *About* tab; it starts with `C`).
2. Copy the Helm app's **Bot User OAuth Token** (`xoxb-…`) from the Slack app settings → *OAuth & Permissions*. It needs `chat:write` and `files:write`, which Helm already has.
3. In LocalVoice → **Settings → Meetings**:
   - switch on **Enable Meetings**;
   - paste the bot token and click **Save token** (it is stored in macOS Keychain, never in a file);
   - enter the meetings channel ID and the sync channel ID;
   - choose **Personal** or **Company** for this Mac and adjust the label (for example "Company Mac");
   - set the reminder lead time;
   - click **Test connection**. It checks the token and posts this Mac's agenda to `#meetings-sync`.
4. Grant permissions when macOS asks, or from the **Meetings** tab → *Permissions*:
   - **Calendars** (Privacy & Security → Calendars): needed for the agenda and prompts.
   - **Screen & System Audio Recording** (Privacy & Security → Screen & System Audio Recording): needed to capture the other participants. Only audio is kept; no video is saved. Quit and reopen LocalVoice after turning it on. Without it, meetings are recorded from your microphone only and speakers are labelled by diarization.
   - **Microphone** and **Notifications**: allow when prompted.

The Deepgram API key from the dictation setup is used for meetings too. Meeting audio and transcripts stay in `~/Library/Application Support/LocalVoice/Recordings/` until you delete them from History.

## Build and test

Build and install:

```sh
./Scripts/build-app.sh
```

Build into `build/` without installing or restarting the installed app:

```sh
./Scripts/build-app.sh --no-install
```

Run the deterministic checks:

```sh
swiftc -parse-as-library -swift-version 5 Sources/RecordingStartGate.swift Tests/RecordingStartGateTests.swift -o /tmp/LocalVoice-state-check
/tmp/LocalVoice-state-check

# Meetings: agenda and transcript payloads, Deepgram parsing, timing rules, Slack client (mocked network)
swiftc -parse-as-library -swift-version 5 Sources/MeetingModels.swift Sources/SlackClient.swift Tests/MeetingsTests.swift -o /tmp/LocalVoice-meetings-check
/tmp/LocalVoice-meetings-check

# Meetings audio: track writing and the stereo mixdown, with synthetic tones (no microphone)
swiftc -parse-as-library -swift-version 5 -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
  Sources/MeetingModels.swift Sources/MeetingRecorder.swift Tests/MeetingAudioTests.swift -o /tmp/LocalVoice-audio-check
/tmp/LocalVoice-audio-check
```

`Tests/MeetingLiveCheck.swift` is an optional live check that sends about 15 seconds of synthesized speech to Deepgram; its header has the commands.

## Downloading a ready-to-run app

GitHub provides source archives for this repository, but this project does not currently publish a ready-to-run `.app`. The build uses a local self-signed identity, which is intended for building on your own Mac. Direct distribution to other Macs requires a Developer ID signature and Apple notarization; see [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Project layout

- `Sources/` — app UI, recording/history state, Fn monitoring, and Deepgram requests
- `Sources/Meeting*.swift`, `CalendarService.swift`, `SlackClient.swift`, `SlackKeychain.swift` — Meetings mode
- `Scripts/setup-signing.sh` — creates a per-Mac local signing identity
- `Scripts/build-app.sh` — builds, signs, installs, and opens LocalVoice
- `Scripts/make-icon.swift` — generates the app icon
- `Tests/` — deterministic recording-state and meetings checks

## License

MIT. See [LICENSE](LICENSE).
