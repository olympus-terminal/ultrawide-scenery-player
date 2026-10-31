# ultrawide-scenery-player

Play scenery, walking, hiking, rain-forest and drone videos with **your own soundtrack**,
smoothly, full screen, at 4K/60. It is a small launcher and an [mpv](https://mpv.io) Lua script.
It is built for videos that have no sound, or whose sound you'd rather replace.

- **Video sound off by default.** Pick any music: a file, a folder or a playlist. It plays shuffled and looped next to the video.
- **Smooth 4K60 playback.** It uses hardware decoding (NVDEC/VAAPI), the `gpu-next` renderer and display-resampled timing.
  A 1 GiB read-ahead cache keeps playback steady from slow or busy USB disks.
- **360 videos fill an ultrawide (32:9) screen** instead of showing as a small 16:9 picture between black bars.
  Both equirectangular 360 files and YouTube's cubemap (EAC) WebMs are detected automatically. Nothing is re-encoded.
- **Fixes a common NVIDIA + conda problem** that silently drops mpv to software rendering (see below).

## Install

You need `mpv` (0.36 or newer), `ffprobe` (part of ffmpeg) and bash. On Debian/Ubuntu: `sudo apt install mpv ffmpeg`.

```bash
git clone https://github.com/olympus-terminal/ultrawide-scenery-player.git
ln -s "$PWD/ultrawide-scenery-player/scenery" ~/.local/bin/scenery
```

## Use

```bash
scenery forest_walk_4k.mp4                         # silent, full screen
scenery -s ~/Music/ambient/ --loop ~/Videos/scenery/   # your music, shuffled; videos loop
scenery --keep-audio waterfall.mp4                 # keep the video's own sound
scenery hike_360.webm --script-opts=vr360-w=5120,vr360-h=1440   # 360 on a 5120x1440 screen
```

Any other argument goes straight to mpv, so normal mpv options and keys work as usual.
The soundtrack runs in a second mpv. Pausing the video does not pause the music,
and the music stops when the video player closes.

### 360 videos on an ultrawide

`Alt+m` cycles between these modes:

| mode | what you see |
|---|---|
| `trim` (default) | full 360° around. The bottom 22.7% is cut off (the ground under the camera, where tripods and logo patches sit) and the rest is stretched to fill the screen |
| `stretch` | the whole frame stretched to fill the screen |
| `band` | no stretching: a 1:1 pixel band of the full 360°, ±45° up and down. `Alt+Up/Down` moves the band |
| `view` | cylindrical reprojection (CPU). `Alt+Left/Right` turns, `Alt+Up/Down` tilts, `Alt+=`/`Alt+-` changes the field of view |

Other keys: `Alt+0` resets the view, `Alt+v` switches 360 handling off and on,
and `Alt+f`/`Alt+c` force equirectangular or cubemap handling for untagged files.

Options go in `--script-opts=vr360-<name>=<value>`: `mode`, `w`/`h` (screen size, default 3840x1080),
`trim` (the fraction cut from the bottom, 0 keeps everything), `hfov`, `pitch`, `interp`.

You can also use the script without the launcher: `mpv --script=/path/to/vr360_ultrawide.lua video.webm`.
It leaves normal videos alone, so it can stay loaded for mixed playlists.

## Notes from testing (mpv 0.37, NVIDIA 580, Linux/X11)

- **conda breaks NVIDIA OpenGL in mpv.** conda's `base` environment sets
  `__EGL_VENDOR_LIBRARY_DIRS` to a folder that only lists Mesa. mpv then logs
  `libEGL warning: egl: failed to create dri2 screen` and `Suspected software renderer`,
  tries DRM (`Permission denied`) and falls back to another backend. `scenery` unsets the variable for mpv.
  For a plain alias, use `alias m='env -u __EGL_VENDOR_LIBRARY_DIRS mpv ...'`.
- **360 files use software decoding from the start.** In testing, switching the hardware decoder
  during playback (NVDEC under `gpu-next`) caused an NVIDIA GPU page fault (`Xid 31` in `journalctl -k`) and a hung mpv.
  The script picks the decoder before playback starts and never changes it mid-file.
  Software decoding kept up comfortably on a 32-thread CPU: 4K VP9 at 6x real time, 8K AV1 at 3.4x.
- If mpv ever hangs and ignores `q`, check `journalctl -k | grep Xid`. A plain `kill <pid>` was enough to free the GPU.

## License

MIT
