# Every Noise — features

A detailed tour of what the app can do. For installation and a quick start see
[README.md](README.md).

## The inaudible tone on a schedule

The core job: at the chosen interval the app plays a short sine pulse at a frequency people
cannot hear but the amplifier's signal detector can.

| Setting | Values | Default |
| --- | --- | --- |
| Frequency | 22, 20, 19, 18, 17 kHz plus two low presets — 20 and 10 Hz | 20 kHz |
| Interval | 15 s, 30 s, 1, 2, 3, 5, 10, 15, 30 min, 1 hour | 30 s |
| Pulse length | 0.25 / 0.5 / 1 / 2 / 3 s | 1 s |
| Level | 1–100 % | 12 % (−18 dBFS) |

The **Test pulse** button in Settings, right below the frequency picker, plays a pulse with
the current settings immediately. It works while pulses are paused too: in that case the
audio chain is released right after the pulse so the Mac can still fall asleep. The same
action is in the menu bar under **Play now**. Both are written to the log when logging is on.

The pulse has a 20 ms raised-cosine fade in and out. Without it the abrupt start of a sine
produces a broadband click that is audible even though the tone itself is not.

Pulse length and level matter more than they look: auto-standby detectors integrate the
signal, and for some of them one second is not enough. A level of 10–15 % is a sensible
start — a detector usually needs only a few millivolts.

## Connection detection and frequency adaptation

The app reads the connection type through CoreAudio and knows the frequency ceiling of the
current chain — the lower of two limits: the codec and 0.45 × the device sample rate. If the
chosen preset is above the ceiling, the closest suitable one is played and **your setting
stays untouched** — switch back to another device and it plays again.

| Connection | Ceiling | What plays when 20 kHz is selected |
| --- | --- | --- |
| 3.5 mm jack, USB, HDMI at 48 kHz | 21.6 kHz | 20 kHz |
| The same at 44.1 kHz | 19.8 kHz | 19 kHz |
| USB DAC at 96 kHz and above | 43 kHz and above | 20 kHz, 22 kHz available |
| AirPlay, Bluetooth | ~18 kHz (AAC codec) | 18 kHz |

The automatic choice never goes below 17 kHz: teenagers and children hear that range, and
only the user should make that call. Adaptation is turned off with the **Adapt frequency to
the connection** toggle — a warning takes its place.

Device changes are tracked through the CoreAudio HAL directly, not only through the audio
engine. That is what catches the speakers ↔ 3.5 mm jack switch: on a MacBook these are one
device with different data sources, and the usual configuration-change notifications do not
fire for it.

## Route hold

AirPlay and Bluetooth tear the session down when there is no audio. Between pulses the
amplifier has time to fall asleep, and reconnection eats the start of the next pulse — the
app runs, but to no effect.

With route hold the app continuously emits the same frequency at −70 dBFS. That is enough
for the stream not to count as empty, and it is 40 dB below the threshold of hearing, so
tweeters are not stressed. The carrier loops over a whole number of periods, so there is no
click at the loop seam.

**Automatic** enables route hold for AirPlay, Bluetooth and aggregate devices; a jack or USB
does not need it. **Always** is useful when a USB DAC mutes its own output on silence and
clicks on the first pulse.

## The app does not keep your Mac awake

While audio is playing, macOS holds `PreventUserIdleSystemSleep` on the app's behalf — this
applies to any program that plays sound. Without countermeasures the Mac would never fall
asleep.

So pulses stop and the audio chain is released in two cases:

- **user inactivity** — 5 minutes without keyboard or mouse. The first action resumes pulses
  immediately, without waiting for the next tick;
- **going to sleep** — on the system notification, before the Mac actually sleeps. The audio
  device is released cleanly and comes back from scratch after wake.

If the Mac wakes on its own — for scheduled maintenance or network activity — pulses stay
paused: nobody is at the machine, so there is nothing to keep the amplifier awake for.

Turned off with the **Pause when the Mac is idle** toggle.

## Warnings about the audio chain

The Status tab and the log report when the tone physically cannot reach the amplifier:

- the system is muted or the volume is at zero;
- an analog output at a system volume below 10 % — the signal may not reach the detector's
  threshold;
- the frequency was lowered because of the device format;
- the AirPlay or Bluetooth codec will cut the selected frequency (when adaptation is off).

The same tab shows the current device, connection type, sample rate, system volume, the time
of the last and next pulse and the pulse counter for this session.

## Audit log

The file is `~/Library/Logs/EveryNoise/every-noise.log`, rotated at 512 KB with 5
generations kept — about a week of history at a 30-second interval. Writes are atomic, so
the file stays valid under any circumstances.

Recorded events: start and stop, every pulse with its settings and output device, route
changes, frequency reductions, route hold going on and off, pauses for inactivity and sleep,
settings changes, and every warning and error.

The Log tab shows the last 500 entries, including the ones read from the file at launch,
filters them by level and reveals the file in Finder. The **Logging** checkbox in the bottom
bar stops recording; the boundaries of the pause are marked in the log itself so the file has
no unexplained gap.

## Menu bar and window

The menu bar menu holds the current state, pause and resume, a pulse on demand, quick
frequency and interval switching, opening the window and quitting. The icon is the same wave
as the app icon, dimmed while paused.

The Dock icon only shows while the window is open: the app lives in the menu bar and does not
take Dock space for nothing. A second copy will not start — launching again activates the
running one.

## Interface language

English and Russian, switched in Settings. The language changes on the fly, without
restarting the app; on first launch it follows the system language. Log lines that are
already written keep the language they were written in — that is history, not interface.

## Launch at login and build info

Launch at login uses `SMAppService`; the system requires the app to live in `/Applications`.
A registration failure goes to the log.

At the bottom of Settings you will find the version, build number, commit, tag, build date
and architectures. The **Copy for a report** button puts all of it, together with the macOS
version, on the clipboard.
