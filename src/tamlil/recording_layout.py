# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Filesystem layout for one Tamlil recording."""

from __future__ import annotations

from pathlib import Path


class RecordingLayout:
    def __init__(self, directory: str | Path):
        self.directory = Path(directory)

    @property
    def raw_dir(self) -> Path:
        return self.directory / "raw"

    @property
    def work_dir(self) -> Path:
        return self.directory / "work"

    @property
    def final_dir(self) -> Path:
        return self.directory / "final"

    @property
    def logs_dir(self) -> Path:
        return self.directory / "logs"

    @property
    def raw_system(self) -> Path:
        return self.raw_dir / "system.wav"

    @property
    def raw_mic(self) -> Path:
        return self.raw_dir / "mic.wav"

    def _audio(self, canonical: Path) -> Path:
        """The track's file on disk: the canonical wav, or the compacted .m4a
        the pipeline replaces it with once the transcript is final. Returns the
        canonical path when neither exists so callers' .exists() checks work."""
        if canonical.exists():
            return canonical
        m4a = canonical.with_suffix(".m4a")
        return m4a if m4a.exists() else canonical

    @property
    def raw_system_audio(self) -> Path:
        return self._audio(self.raw_system)

    @property
    def raw_mic_audio(self) -> Path:
        return self._audio(self.raw_mic)

    @property
    def work_mic_denoised_audio(self) -> Path:
        return self._audio(self.work_mic_denoised)

    @property
    def work_terms_local(self) -> Path:
        return self.work_dir / "terms.local.txt"

    @property
    def work_mic_denoised(self) -> Path:
        return self.work_dir / "mic.denoised.wav"

    @property
    def work_mic_asr(self) -> Path:
        return self.work_dir / "mic.asr.json"

    @property
    def work_system_asr(self) -> Path:
        return self.work_dir / "system.asr.json"

    @property
    def work_merged_raw(self) -> Path:
        return self.work_dir / "merged.raw.json"

    @property
    def work_merged_uncertain(self) -> Path:
        return self.work_dir / "merged.uncertain.json"

    @property
    def work_echo_report(self) -> Path:
        return self.work_dir / "echo.report.json"

    @property
    def work_pipeline_timings(self) -> Path:
        return self.work_dir / "pipeline.timings.json"

    @property
    def final_transcript_json(self) -> Path:
        return self.final_dir / "transcript.json"

    @property
    def final_transcript_md(self) -> Path:
        return self.final_dir / "transcript.md"

    @property
    def final_summary_md(self) -> Path:
        return self.final_dir / "summary.md"

    @property
    def pipeline_log(self) -> Path:
        return self.logs_dir / "pipeline.log"

    def asr_json_for(self, wav: Path) -> Path:
        stem = wav.name.split(".", 1)[0]
        if stem == "mic":
            return self.work_mic_asr
        if stem == "system":
            return self.work_system_asr
        return self.work_dir / f"{wav.stem}.asr.json"

    def prepare(self) -> None:
        for directory in (self.raw_dir, self.work_dir, self.final_dir, self.logs_dir):
            directory.mkdir(parents=True, exist_ok=True)
