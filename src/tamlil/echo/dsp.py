# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Waveform DSP for echo reconciliation: session/segment delay estimation and
normalized cross-correlation. Everything here operates on decoded mono float32
arrays (see the package's ``_load``) — no I/O, no transcript text."""

from __future__ import annotations

import numpy as np

SR = 16000  # decode rate; echo needs fine waveform structure
MAX_LAG_S = 0.5  # search the session speaker->mic delay within +-0.5 s
SEARCH_S = 0.3  # per-segment lag search around the session delay
LAG_TOL_S = 0.06  # peak must sit within +-60 ms of the physical delay
REBROADCAST_LAG_TOL_S = 0.25  # network jitter shifts per-segment rebroadcast lag
NCC_MIN = 0.25  # min peak correlation (real speech tops out ~0.19)
REBROADCAST_NCC_MIN = 0.4  # rebroadcast searches a 4x wider window than playback
# (REBROADCAST_LAG_TOL_S vs LAG_TOL_S), so a spurious
# peak has ~4x the chances to clear NCC_MIN; deleting
# the primary remote record on such a fluke is costly,
# so require a clearly stronger match on this path.
MIN_DUR = 0.3  # too short to correlate reliably
BROAD_DELAY_MAX_S = 12.0
BROAD_DELAY_FPS = 50
BROAD_DELAY_MIN_CONFIDENCE = 0.18


def _estimate_delay(mic: np.ndarray, sysv: np.ndarray, them: list[dict]) -> int | None:
    """Delay tau (samples) such that mic[i] aligns with sysv[i+tau], found from
    the highest-energy 'Them' segment (most likely to carry strong echo)."""
    ml = int(MAX_LAG_S * SR)
    best = None
    for t in them:
        a, b = int(t["start"] * SR), int(t["end"] * SR)
        if b - a < int(0.5 * SR) or a - ml < 0 or b + ml > len(sysv) or b > len(mic):
            continue
        e = float((sysv[a:b] ** 2).sum())
        if best is None or e > best[0]:
            best = (e, a, b)
    if best is None:
        return None
    _, a, b = best
    m = mic[a:b]
    s = sysv[a - ml : b + ml]
    num = np.correlate(s, m, mode="valid")
    cs = np.concatenate(([0.0], np.cumsum(s.astype(np.float64) ** 2)))
    we = cs[len(m) :] - cs[: -len(m)]
    mn = np.sqrt((m.astype(np.float64) ** 2).sum())
    k = int(np.argmax(np.abs(num / (np.sqrt(we) * mn + 1e-9))))
    return (a - ml + k) - a


def _energy_envelope(audio: np.ndarray, fps: int = BROAD_DELAY_FPS) -> np.ndarray:
    hop = max(1, SR // fps)
    n = len(audio) // hop
    if n == 0:
        return np.empty(0, dtype=np.float32)
    frames = audio[: n * hop].reshape(n, hop)
    env = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))
    std = float(env.std())
    if std < 1e-9:
        return np.empty(0, dtype=np.float32)
    return ((env - float(env.mean())) / std).astype(np.float32)


def _correlation_curve(
    mic: np.ndarray,
    sysv: np.ndarray,
    lo_s: float,
    hi_s: float,
) -> tuple[np.ndarray, np.ndarray] | None:
    """Envelope cross-correlation score per lag (in envelope hops) over
    [lo_s, hi_s]. Positive lag: mic[i] aligns with sysv[i+lag], the mic leads."""
    n = min(len(mic), len(sysv))
    mic_env = _energy_envelope(mic[:n])
    sys_env = _energy_envelope(sysv[:n])
    if len(mic_env) == 0 or len(sys_env) == 0:
        return None
    hard_cap = len(mic_env) - 1
    lo = max(int(round(lo_s * BROAD_DELAY_FPS)), -hard_cap)
    hi = min(int(round(hi_s * BROAD_DELAY_FPS)), hard_cap)
    lags, scores = [], []
    for lag in range(lo, hi + 1):
        if lag >= 0:
            a = mic_env[: len(mic_env) - lag]
            b = sys_env[lag:]
        else:
            a = mic_env[-lag:]
            b = sys_env[: len(sys_env) + lag]
        if len(a) < BROAD_DELAY_FPS:
            continue
        lags.append(lag)
        scores.append(float(np.dot(a, b) / len(a)))
    if not lags:
        return None
    return np.array(lags), np.array(scores)


def _estimate_broad_delay(
    mic: np.ndarray,
    sysv: np.ndarray,
    lag_range_s: tuple[float, float] = (-BROAD_DELAY_MAX_S, BROAD_DELAY_MAX_S),
) -> tuple[int, float] | None:
    """Delay tau (samples) such that mic[i] aligns with sysv[i+tau]."""
    curve = _correlation_curve(mic, sysv, *lag_range_s)
    if curve is None:
        return None
    lags, scores = curve
    k = int(np.argmax(scores))
    if scores[k] < BROAD_DELAY_MIN_CONFIDENCE:
        return None
    return int(round(lags[k] / BROAD_DELAY_FPS * SR)), float(scores[k])


# Cross-track paths, told apart by lag sign:
# playback = remote audio out the speakers into the mic (system leads by ms);
# rebroadcast = room speech returning through other in-room participants'
# meeting clients (mic leads by a network round trip).
PLAYBACK_LAG_S = (-1.0, 0.25)
REBROADCAST_LAG_S = (0.3, 12.0)
# Continuous speech correlates over a broad lag plateau; a second direction's
# peak is real only if the correlation dips well below it between the peaks.
SECONDARY_VALLEY_RATIO = 0.5


def _directional_delays(mic: np.ndarray, sysv: np.ndarray) -> dict[str, tuple[int, float]]:
    """Independently confident delay estimates per direction; a direction with
    no confident, well-separated envelope-correlation peak is absent."""
    curve = _correlation_curve(mic, sysv, PLAYBACK_LAG_S[0], REBROADCAST_LAG_S[1])
    if curve is None:
        return {}
    lags, scores = curve

    def window_peak(lag_range: tuple[float, float]) -> tuple[int, float] | None:
        mask = (lags >= lag_range[0] * BROAD_DELAY_FPS) & (lags <= lag_range[1] * BROAD_DELAY_FPS)
        if not mask.any():
            return None
        idx = np.flatnonzero(mask)
        k = idx[int(np.argmax(scores[idx]))]
        if scores[k] < BROAD_DELAY_MIN_CONFIDENCE:
            return None
        return int(k), float(scores[k])

    peaks = {
        name: peak
        for name, lag_range in (("playback", PLAYBACK_LAG_S), ("rebroadcast", REBROADCAST_LAG_S))
        if (peak := window_peak(lag_range)) is not None
    }
    if len(peaks) == 2:
        primary = max(peaks, key=lambda name: peaks[name][1])
        secondary = "playback" if primary == "rebroadcast" else "rebroadcast"
        k1, _ = peaks[primary]
        k2, s2 = peaks[secondary]
        lo, hi = sorted((k1, k2))
        valley = float(scores[lo : hi + 1].min())
        if valley > s2 * SECONDARY_VALLEY_RATIO:
            del peaks[secondary]
    return {
        name: (int(round(lags[k] / BROAD_DELAY_FPS * SR)), score)
        for name, (k, score) in peaks.items()
    }


def _peak_ncc(
    mic: np.ndarray, sysv: np.ndarray, tau: int, s0: float, e0: float
) -> tuple[float, int]:
    """Peak normalized cross-correlation of the mic segment against the system,
    searching lags near tau. Returns (ncc, offset-from-tau in samples)."""
    a, b = int(s0 * SR), int(e0 * SR)
    if b - a < int(MIN_DUR * SR) or b > len(mic):
        return 0.0, 0
    search = int(SEARCH_S * SR)
    lo, hi = a + tau - search, b + tau + search
    if lo < 0 or hi > len(sysv):
        return 0.0, 0
    m = mic[a:b]
    s = sysv[lo:hi]
    num = np.correlate(s, m, mode="valid")
    cs = np.concatenate(([0.0], np.cumsum(s.astype(np.float64) ** 2)))
    we = cs[len(m) :] - cs[: -len(m)]
    mn = np.sqrt((m.astype(np.float64) ** 2).sum())
    ncc = np.abs(num / (np.sqrt(we) * mn + 1e-9))
    k = int(np.argmax(ncc))
    return float(ncc[k]), (lo + k) - a - tau


def _is_echo(mic: np.ndarray, sysv: np.ndarray, tau: int, seg: dict) -> bool:
    ncc, offset = _peak_ncc(mic, sysv, tau, seg["start"], seg["end"])
    return ncc >= NCC_MIN and abs(offset) <= int(LAG_TOL_S * SR)


def _is_rebroadcast(mic: np.ndarray, sysv: np.ndarray, tau: int, seg: dict) -> bool:
    """True when this system segment's audio already exists on the mic one
    rebroadcast delay earlier — room speech coming back through the meeting
    app. The per-segment lag jitters with the network, hence the wider
    tolerance than the acoustic playback path."""
    ncc, offset = _peak_ncc(sysv, mic, -tau, seg["start"], seg["end"])
    return ncc >= REBROADCAST_NCC_MIN and abs(offset) <= int(REBROADCAST_LAG_TOL_S * SR)
