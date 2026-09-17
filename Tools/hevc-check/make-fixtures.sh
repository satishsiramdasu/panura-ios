#!/usr/bin/env bash
# HEVC HDR10 fixtures tagged hev1 — the tag Apple's players refuse — for
# hevc-check: an MP4 with moov first, one with moov last, and an fMP4 HLS stream
# with a master playlist whose CODECS names hev1.
set -euo pipefail

OUT="$1"
mkdir -p "$OUT"
cd "$OUT"

X265='hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:keyint=50:min-keyint=50:scenecut=0:open-gop=0:log-level=error'

encode() {
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1280x720:rate=25" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 8 -map 0:v -map 1:a \
    -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params "$X265" \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
    -c:a aac -b:a 128k \
    "$@"
}

hls() {  # hls <dir> <tag>
  mkdir -p "$1"
  encode -tag:v "$2" -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 \
    -hls_fmp4_init_filename init.mp4 -hls_segment_filename "$1/seg%03d.m4s" \
    -master_pl_name master.m3u8 "$1/index.m3u8"
}

encode -tag:v hev1 -movflags +faststart hev1-faststart.mp4
encode -tag:v hev1 hev1-moov-at-end.mp4

hls hls-hev1 hev1
# Control: the same stream as FFmpeg writes it for Apple. If this does not play
# either, the failure is the runner or the harness, not the rename.
hls hls-hvc1 hvc1

ffprobe -hide_banner -loglevel error -select_streams v \
  -show_entries stream=codec_tag_string,color_transfer -of compact hev1-faststart.mp4
ls hls-hev1
cat hls-hev1/master.m3u8
