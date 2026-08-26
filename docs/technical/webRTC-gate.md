# WebRTC macOS technical gate

Date: 2026-08-26

## Pinned artifact

- Package: `https://github.com/stasel/WebRTC.git`
- Version: `150.0.0`
- Revision: `6ed87f05368632f71dc95c89c14c051561710925`
- Artifact checksum: `f9890492b0016e4c88ab20f07867b8b420054caedc8a692b2ec6ac041f3cf6b2`

`swift package resolve` and `swift build` both succeeded. The release names its
macOS library directory `macos-x86_64_arm64` (rather than the implementation
plan's `macos-arm64_x86_64`). Running `lipo -archs` on the packaged binary
reported:

```text
x86_64 arm64
```

## Unsigned app load

The first app launch failed with this exact dyld error:

```text
Library not loaded: @rpath/WebRTC.framework/WebRTC
Reason: tried: '.../MacChannel.app/Contents/MacOS/WebRTC.framework/WebRTC' (no such file)
```

This was a bundle assembly defect rather than an unavailable or incompatible
artifact: SwiftPM had copied the framework into its debug products directory,
but `Scripts/build-app.sh` had copied only the executable. The bundler now embeds
that framework beside the executable, matching the executable's
`@loader_path` runtime search path.

After that correction, the unsigned/ad-hoc local app executable exited with
status 0, `open .build/MacChannel.app` returned status 0, and
`DYLD_PRINT_LIBRARIES=1` showed the bundled
`Contents/MacOS/WebRTC.framework/Versions/A/WebRTC` being loaded. No equivalent
artifact was selected because the pinned 150.0.0 artifact passed the actual
slice, build, and load gates.

## Data-channel backpressure API

The M150 Objective-C surface exposes read-only `bufferedAmount` and
`dataChannel(_:didChangeBufferedAmount:)`; it does not expose the browser API's
settable `bufferedAmountLowThreshold`. MacChannel therefore uses the callback
with a 1 MiB software high-water mark and resumes blocked senders only after the
reported amount reaches the 256 KiB software low-water mark. Callback and frame
queues are bounded and overflow closes the affected channel instead of dropping
ordered application data silently.
