# Android Emulator mod

Shows an Android emulator or a plugged-in device in a Govi pane. Click to tap,
drag to swipe, scroll to scroll, and type into the field to send text. A second
pane follows `adb logcat`.

It needs the Android SDK's platform tools (`adb`); to start emulators from the
pane it also needs the SDK's `emulator` and at least one virtual device.

```sh
govi mod link app/govi/examples/mods/android-emulator
govi mod enable android-emulator
govi mod open android-emulator/screen
```

The picture is a screenshot taken a few times a second, which is enough for
checking layouts and tapping through an app; it is not a video stream.
