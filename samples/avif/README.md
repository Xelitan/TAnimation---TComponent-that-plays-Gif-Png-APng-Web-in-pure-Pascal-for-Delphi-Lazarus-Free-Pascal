# AVIF test animations

| File | Source | Notes |
|---|---|---|
| `ball-alpha-xelitan.avif` | TAvifAnimation (this package) | 160x160, 30 frames, 4:2:0 8-bit + alpha track |
| `gradient-xelitan-420.avif` | TAvifAnimation (this package) | 240x160, 24 frames, 4:2:0 8-bit, inter frames with motion |
| `testsrc2-libaom-420.avif` | ffmpeg + libaom (`testsrc2`) | 320x240, 30 frames, 4:2:0 8-bit |
| `mandelbrot-libaom-444.avif` | ffmpeg + libaom (`mandelbrot`) | 192x192, 24 frames, 4:4:4 8-bit |
| `alpha_video.avif` | libavif test data | 640x480, 48 frames, alpha track |
| `star.avif` | libavif test data | 159x159, 5 frames, alpha track |
| `colors-animated-8bpc.avif` | libavif test data | 150x150, 5 frames |
| `colors-animated-12bpc-keyframes-0-2-3.avif` | libavif test data | 64x64, 5 frames, 12-bit, translucent |

The libavif files come from https://github.com/AOMediaCodec/libavif (`tests/data`)
and are covered by libavif's licence.
