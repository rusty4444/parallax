# Sending videos

Pick **Photo or video** (gallery), **Record video** (system camera, up to
4 minutes) or **File** in the composer's attachment menu.

- Videos of 20 MB or less, at most 1080p on the short side, are sent
  unchanged.
- Larger ones are re-encoded on the phone to H.264/AAC MP4 with the short
  side at 720 px (`VideoTools.kt`, androidx Media3 Transformer). The video
  bitrate is chosen from the length so the result fits in 20 MB: up to
  2.5 Mb/s, and no lower than 0.5 Mb/s, which allows about 4 minutes.
  Longer videos are refused with a message.
- At upload the video's width, height, duration and a JPEG poster frame
  (800 px, `MediaMetadataRetriever`) are read natively. The poster is
  uploaded first (encrypted in encrypted rooms) and referenced from
  `info.thumbnail_file` / `thumbnail_url`, as for images.

The 20 MB limit comes from the durable outbox, which keeps unsent
attachments in Android's encrypted key store until they are delivered.

## Checking the native tools on a device

`integration_test/video_tools_test.dart` probes and compresses real files.

```sh
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 -f lavfi -i sine=frequency=440 \
  -t 20 -c:v libx264 -b:v 12M -c:a aac -pix_fmt yuv420p -shortest video_test.mp4
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=440 \
  -t 5 -c:v libx264 -b:v 2M -c:a aac -pix_fmt yuv420p -shortest video_small.mp4
# Install once so the app's files directory exists, then push and run:
flutter test integration_test/video_tools_test.dart -d <device>   # fails: no fixtures
adb push video_test.mp4 video_small.mp4 /sdcard/Android/data/net.samrussell.parallax/files/
flutter test integration_test/video_tools_test.dart -d <device>
```

On the Android emulator (12 Nov 2026) the 30.9 MB 1080p clip became a
6.8 MB 1280x720 MP4 in 14 s, with its 20 s duration and a 22 KB poster.
