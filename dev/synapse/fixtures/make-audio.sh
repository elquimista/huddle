#!/bin/bash
# Regenerates the audio files that `seed.py audio` sends. Needs ffmpeg (brew install ffmpeg).
# Everything is synthesised from sine waves here, so nothing is recorded or borrowed.
#   voice.ogg   Ogg Opus, mono    a voice-message-shaped sound, with its waveform in audio.json
#   song.mp3    MP3, stereo       a rising arpeggio
#   chime.ogg   Ogg Vorbis        two notes; a format macOS only reads from 15.4 on
set -euo pipefail
cd "$(dirname "$0")"
quiet=(-hide_banner -loglevel error -y)

# A pitch that drifts, with overtones, shaped into syllables and phrases with pauses between.
voice='0.5*(sin(2*PI*(140+30*sin(2*PI*0.4*t))*t)+0.5*sin(4*PI*(140+30*sin(2*PI*0.4*t))*t)+0.3*sin(6*PI*140*t))*pow(abs(sin(2*PI*1.9*t)),1.5)*(0.25+0.75*pow(abs(sin(2*PI*0.21*t+0.6)),2))*(1-0.9*gt(mod(t,3.1),2.6))'
ffmpeg "${quiet[@]}" -f lavfi -i "aevalsrc='$voice':s=48000:d=8.4" -c:a libopus -b:a 24k -ac 1 voice.ogg

note='220*pow(2,floor(mod(t*4,8))*2/12)'
ffmpeg "${quiet[@]}" -f lavfi -i "aevalsrc='0.45*sin(2*PI*$note*t)*exp(-4*mod(t*4,1))|0.45*sin(2*PI*$note*t+0.6)*exp(-4*mod(t*4+0.5,1))':s=44100:d=14" \
    -c:a libmp3lame -b:a 64k song.mp3

ffmpeg "${quiet[@]}" -f lavfi -i "aevalsrc='0.5*sin(2*PI*880*t)*exp(-3*t)+0.5*sin(2*PI*1318.5*t)*exp(-3*max(t-0.35,0))*gt(t,0.35)':s=44100:d=3:c=stereo" \
    -c:a vorbis -strict -2 chime.ogg

# The voice message's waveform, as Matrix clients send it: 100 loudness values from 0 to 1024.
ffmpeg "${quiet[@]}" -i voice.ogg -f s16le -ar 8000 -ac 1 voice.raw
python3 - <<'PY'
import array, json
samples = array.array("h"); samples.frombytes(open("voice.raw", "rb").read())
size = len(samples) // 100
peaks = [max(abs(v) for v in samples[i * size:(i + 1) * size]) for i in range(100)]
top = max(peaks) or 1
json.dump({"voice": {"duration_ms": round(len(samples) / 8), "waveform": [round(p * 1024 / top) for p in peaks]},
           "song": {"duration_ms": 14000}, "chime": {"duration_ms": 3000}}, open("audio.json", "w"))
PY
rm voice.raw
ls -l voice.ogg song.mp3 chime.ogg audio.json
