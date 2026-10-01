# GPT Call Mixer AudioServerPlugIn

This directory contains a new, standalone Core Audio HAL plug-in source. It does
not replace or modify the existing `MeetVoiceBridge` implementation.

The same `GPTCallMixer.c` is compiled twice:

| Build define | Device shown by Core Audio | Bundle ID | Purpose |
| --- | --- | --- | --- |
| `GPT_CALL_MIXER_ROUTE=1` | `GPT Call Mixer → ChatGPT` | `jp.local.gptcallmixer.driver.to-chatgpt` | ChatGPT app or ChatGPT web input/output route |
| `GPT_CALL_MIXER_ROUTE=2` | `GPT Call Mixer → Call` | `jp.local.gptcallmixer.driver.to-call` | Meet, Discord, or another call client route |

Each bundle has distinct device, model, box, and factory identifiers. They can
therefore be registered as two independent virtual devices even though their
implementation comes from one source file. The standard AudioServerPlugIn type
UUID remains common to both bundles.

## Audio behavior

Each device is a 2-channel, interleaved, native-endian float32 device at a fixed
48,000 Hz nominal rate. Its output stream is the producer and its input stream is
a non-consuming reader of the same absolute sample-time ring:

```text
client writes output stream --WriteMix--> absolute-time ring --ReadInput--> client reads input stream
```

`WriteMix` indexes frames using `mOutputTime.mSampleTime`; `ReadInput` indexes
frames using `mInputTime.mSampleTime`. Every ring slot carries its absolute frame
tag. A missing or stale tag produces silence. Input reads do not advance a shared
consumer head, so more than one input client can read the same time line.

The IO callbacks contain no mutex, allocation, Core Foundation, dispatch, logging,
or blocking operation. Sample bits are stored as 32-bit atomics; samples are stored
first and then published by a release-store of the slot tag. A writer first
invalidates the previous tag, which keeps a reader from accepting an old generation
while a slot is being reused.

The device reports a 16,384-frame zero-timestamp period, satisfying the
`AudioServerPlugIn.h` minimum of 10,923 frames. The device latency is 256 frames
and the stream latency is 0 frames, so HAL does not add the same latency twice;
the timestamp period is not used as a latency value.

Both streams are fixed active and report `kAudioStreamPropertyIsActive` as
non-settable. This avoids a state change without the corresponding host property
notification.

The two HAL devices are independent loopback buses. The driver alone does not
perform the complete application-level matrix (microphone to both clients,
Call-to-ChatGPT plus speakers, and ChatGPT-to-Call plus speakers). A future
user-space mixer must open the two device output/input streams and connect those
buses to the physical microphone and output. This separation is intentional: the
HAL driver remains a small, reusable endpoint and does not capture or record audio.

Core Audio cannot restrict a virtual device to only Meet or Discord. Any client
that is allowed to select an audio device can select it; the client selection is
manual. The `Call` label is a routing convention, not an OS-level access control.

## Source and license

`GPTCallMixer.c` follows the object/property layout of Apple's `NullAudio`
AudioServerPlugIn sample and adds the absolute-time loopback implementation.
The Apple-provided MIT-style notice is preserved verbatim in
[`LICENSE.txt`](./LICENSE.txt).

## Build and integration

From the repository root, run `./script/build_gpt_call_mixer.sh --verify`.
It builds the application, both x86_64 driver bundles, and the audio ring-buffer
checks without installing or registering the drivers. See the root README for
installation and routing instructions.

The application in `GPTCallMixerApp/` implements the user-space matrix described
above. The driver remains a loopback endpoint; routing depends on the application
and the input/output device selections in each client.

Generated binaries and host-specific verification logs are excluded from Git.
The build copies the Apple license into each driver bundle.
