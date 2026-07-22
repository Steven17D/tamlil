# RNNoise model

`bd.rnnn` — the "beguiling-drafter" RNNoise model from
[GregorR/rnnoise-models](https://github.com/GregorR/rnnoise-models), whose
author disclaims copyright on the weights. (The RNNoise software that ffmpeg's
`arnndn` filter implements is a separate work — Xiph.Org / Jean-Marc Valin,
BSD-3-Clause.) Used by `denoise.py` via ffmpeg's `arnndn` filter to strip
stationary noise (fan/AC hum) from the mic track for clearer Clarify playback.
See `THIRD_PARTY_LICENSES` at the repo root.
