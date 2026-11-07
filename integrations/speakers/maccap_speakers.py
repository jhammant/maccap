#!/usr/bin/env python3
# Copyright (c) 2026 Jonathan Hammant. MIT License: see LICENSE at the repository root.
"""Name consenting, enrolled speakers on MacCap's system stem. Python 3.10+."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib
import inspect
import json
import math
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Protocol

import numpy as np

SPEECHBRAIN_MODEL = "speechbrain/spkrec-ecapa-voxceleb"
PYANNOTE_MODEL = "pyannote/speaker-diarization-community-1"
DEFAULT_VOICEPRINTS = "~/.maccap/voiceprints"
RATE = 48_000
EMBED_RATE = 16_000
FRAME_SAMPLES = 1024
PRIMING_SAMPLES = 2112
MATCH_MARGIN = 0.05
END_GRACE_SECONDS = 4.0
# (cluster, match) cosines measured on two real calls (README "Backends and
# calibration"). Starting points, not guarantees: calibrate on your own calls.
THRESHOLDS = {"speechbrain": (0.55, 0.70), "pyannote": (0.55, 0.70)}


def log(message: str) -> None:
    print(f"speakers: {message}", file=sys.stderr, flush=True)


def number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise ValueError(f"{label} must be a finite number")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{label} must be a finite number")
    return result


def unit_vector(value: Any) -> np.ndarray:
    vector = np.asarray(value, dtype=np.float64)
    if vector.ndim != 1 or not vector.size or not np.isfinite(vector).all():
        raise ValueError("embedding must be a nonempty, finite vector")
    length = float(np.linalg.norm(vector))
    if not math.isfinite(length) or length <= 1e-12:
        raise ValueError("embedding must have nonzero, finite length")
    return vector / length


@dataclass
class Config:
    backend: str = "speechbrain"
    voiceprints: str = DEFAULT_VOICEPRINTS
    cluster_threshold: float = 0.55
    match_threshold: float = 0.70
    min_line_seconds: float = 1.0
    min_cluster_seconds: float = 6.0
    audio_wait_seconds: float = 1.5
    ffmpeg: str = "ffmpeg"

    @classmethod
    def parse(cls, values: dict[str, Any]) -> Config:
        if not isinstance(values, dict):
            raise ValueError("config must be a JSON object")
        unknown = set(values) - set(cls.__dataclass_fields__)
        if unknown:
            raise ValueError(f"unknown config keys: {', '.join(sorted(unknown))}")
        backend = values.get("backend", "speechbrain")
        if not isinstance(backend, str) or not backend.strip():
            raise ValueError("backend must be speechbrain, pyannote or module:attr")
        cluster, match = THRESHOLDS.get(backend, THRESHOLDS["speechbrain"])
        config = cls(
            **{"cluster_threshold": cluster, "match_threshold": match, **values}
        )
        for key in ("cluster_threshold", "match_threshold"):
            value = number(getattr(config, key), key)
            if not -1 <= value <= 1:
                raise ValueError(f"{key} must be between -1 and 1")
            setattr(config, key, value)
        for key in ("min_line_seconds", "min_cluster_seconds", "audio_wait_seconds"):
            value = number(getattr(config, key), key)
            if value < 0 or (key != "audio_wait_seconds" and value == 0):
                raise ValueError(
                    f"{key} must be positive (audio_wait_seconds may be zero)"
                )
            setattr(config, key, value)
        for key in ("voiceprints", "ffmpeg"):
            if (
                not isinstance(getattr(config, key), str)
                or not getattr(config, key).strip()
            ):
                raise ValueError(f"{key} must be a nonempty string")
        return config


class Backend(Protocol):
    model: str

    def embed(self, samples: np.ndarray) -> list[float]: ...


class SpeechBrainBackend:
    model = SPEECHBRAIN_MODEL

    def __init__(self) -> None:
        import torch
        from speechbrain.inference.speaker import EncoderClassifier

        self.torch = torch
        self.encoder = EncoderClassifier.from_hparams(
            source=self.model,
            savedir=str(Path("~/.cache/maccap-speakers/ecapa").expanduser()),
            run_opts={"device": "cpu"},
        )

    def embed(self, samples: np.ndarray) -> list[float]:
        with self.torch.inference_mode():
            result = self.encoder.encode_batch(
                self.torch.from_numpy(samples).unsqueeze(0)
            )
        return result.detach().cpu().reshape(-1).tolist()


class PyannoteBackend:
    model = PYANNOTE_MODEL

    def __init__(self) -> None:
        # Inference and voiceprints stay local; do not enable library telemetry.
        os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
        import torch
        from pyannote.audio.pipelines.speaker_verification import (
            PretrainedSpeakerEmbedding,
        )

        self.torch = torch
        # This is precisely the component used for Community-1 speaker_embeddings.
        self.encoder = PretrainedSpeakerEmbedding(
            {"checkpoint": self.model, "subfolder": "embedding"},
            device=torch.device("cpu"),
            token=os.environ.get("HF_TOKEN"),
        )

    def embed(self, samples: np.ndarray) -> list[float]:
        waveform = self.torch.from_numpy(samples)[None, None, :]
        with self.torch.inference_mode():
            return np.asarray(self.encoder(waveform)).reshape(-1).tolist()


def load_backend(spec: str) -> Backend:
    if spec == "speechbrain":
        backend = SpeechBrainBackend()
    elif spec == "pyannote":
        backend = PyannoteBackend()
    else:
        module, separator, attr = spec.partition(":")
        if not separator or not module or not attr:
            raise ValueError("backend must be speechbrain, pyannote or module:attr")
        backend = getattr(importlib.import_module(module), attr)
        # An exported instance or a zero-argument factory/class is supported.
        if inspect.isclass(backend) or not hasattr(backend, "embed"):
            backend = backend()
    if (
        not isinstance(getattr(backend, "model", None), str)
        or not backend.model.strip()
    ):
        raise ValueError("backend.model must be a nonempty string")
    if not callable(getattr(backend, "embed", None)):
        raise ValueError("backend must expose embed(samples)")
    return backend


# --- Growing AAC segments ---------------------------------------------------


class AudioPending(Exception):
    """The manifest or complete frames do not cover this span yet."""


class ADTSIndex:
    """Byte boundaries of complete 1024-sample ADTS frames; extend, never rescan."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.boundaries = [0]
        self.identity: tuple[int, int] | None = None

    @property
    def frames(self) -> int:
        return len(self.boundaries) - 1

    def extend(self) -> None:
        with self.path.open("rb") as handle:
            stat = os.fstat(handle.fileno())
            identity = (stat.st_dev, stat.st_ino)
            if identity != self.identity or stat.st_size < self.boundaries[-1]:
                self.boundaries = [0]
                self.identity = identity
            offset = self.boundaries[-1]
            while offset + 7 <= stat.st_size:
                handle.seek(offset)
                header = handle.read(7)
                if len(header) < 7:
                    break
                if header[0] != 0xFF or header[1] & 0xF6 != 0xF0:
                    raise ValueError(f"invalid ADTS sync at byte {offset}")
                header_size = 7 if header[1] & 1 else 9
                length = ((header[3] & 3) << 11) | (header[4] << 3) | (header[5] >> 5)
                if length < header_size:
                    raise ValueError(f"invalid ADTS frame length at byte {offset}")
                if offset + length > stat.st_size:
                    break  # keep the incomplete frame's start for the next extension
                channels = ((header[2] & 1) << 2) | (header[3] >> 6)
                if ((header[2] >> 2) & 15) != 3 or channels != 1 or header[6] & 3:
                    raise ValueError(
                        "expected mono 48 kHz ADTS with 1024 samples per frame"
                    )
                offset += length
                self.boundaries.append(offset)

    def span_bytes(self, first: int, stop: int) -> bytes:
        start, end = self.boundaries[first], self.boundaries[stop]
        with self.path.open("rb") as handle:
            handle.seek(start)
            data = handle.read(end - start)
        if len(data) != end - start:
            raise AudioPending("segment changed while reading")
        return data


def ffmpeg_decode(
    args: list[str], data: bytes | None = None, timeout: float = 10
) -> np.ndarray:
    result = subprocess.run(
        args,
        input=data,
        stdin=subprocess.DEVNULL if data is None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-400:]
        raise ValueError(f"ffmpeg failed: {detail}")
    if not result.stdout or len(result.stdout) % 4:
        raise ValueError("ffmpeg returned no usable audio")
    return np.frombuffer(result.stdout, dtype="<f4").astype(np.float32, copy=True)


class SessionAudio:
    def __init__(
        self, directory: Path, config: Config, stopping: threading.Event
    ) -> None:
        self.directory = directory.resolve()
        self.config = config
        self.stopping = stopping
        self.indexes: dict[Path, ADTSIndex] = {}

    def segment(self, start: float, end: float) -> tuple[ADTSIndex, float]:
        with (self.directory / "session.json").open(encoding="utf-8") as handle:
            manifest = json.load(handle)
        if not isinstance(manifest, dict) or not isinstance(
            manifest.get("system_segments"), list
        ):
            raise ValueError("session.json needs system_segments")
        segments = []
        for item in manifest["system_segments"]:
            if not isinstance(item, dict) or not isinstance(item.get("file"), str):
                raise ValueError("invalid system segment")
            offset = number(item.get("start_seconds"), "segment start_seconds")
            path = (self.directory / item["file"]).resolve()
            if not path.is_relative_to(self.directory) or path == self.directory:
                raise ValueError("segment file must stay inside session_dir")
            segments.append((offset, path))
        segments.sort(key=lambda item: item[0])
        eligible = [index for index, item in enumerate(segments) if item[0] <= start]
        if not eligible:
            raise AudioPending("no system segment covers the start")
        chosen = eligible[-1]
        if chosen + 1 < len(segments) and end > segments[chosen + 1][0]:
            raise ValueError("line crosses a system segment boundary; skipping")
        offset, path = segments[chosen]
        if path not in self.indexes:
            self.indexes[path] = ADTSIndex(path)
        return self.indexes[path], offset

    def read_once(self, start: float, end: float) -> np.ndarray:
        index, offset = self.segment(start, end)
        index.extend()
        # Decoded sample n is at offset + (n - 2112) / 48000.
        source_start = (start - offset) * RATE + PRIMING_SAMPLES
        source_end = (end - offset) * RATE + PRIMING_SAMPLES
        if index.frames * FRAME_SAMPLES < source_end:
            raise AudioPending("system audio has not reached the line's end")
        first = max(0, math.floor(source_start / FRAME_SAMPLES) - 2)
        stop = min(index.frames, math.ceil(source_end / FRAME_SAMPLES) + 2)
        data = index.span_bytes(first, stop)
        samples = ffmpeg_decode(
            [
                self.config.ffmpeg,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "aac",
                "-i",
                "pipe:0",
                "-ac",
                "1",
                "-ar",
                str(EMBED_RATE),
                "-f",
                "f32le",
                "pipe:1",
            ],
            data,
        )
        trim = round((source_start - first * FRAME_SAMPLES) * EMBED_RATE / RATE)
        length = round((end - start) * EMBED_RATE)
        if len(samples) < trim + length:
            raise AudioPending("decoded audio is shorter than the requested span")
        return samples[trim : trim + length].copy()

    def read(self, start: float, end: float) -> np.ndarray:
        deadline = time.monotonic() + self.config.audio_wait_seconds
        while not self.stopping.is_set():
            try:
                return self.read_once(start, end)
            except (AudioPending, FileNotFoundError, json.JSONDecodeError) as error:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AudioPending(str(error)) from error
                self.stopping.wait(min(0.1, remaining))
        raise AudioPending("call ended before audio was ready")


# --- Voiceprints ------------------------------------------------------------


def person_name(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or any(ord(c) < 32 for c in value)
    ):
        raise ValueError("person name must be nonempty text without control characters")
    return value.strip()


def voiceprint_files(folder: Path) -> list[tuple[Path, dict[str, Any]]]:
    records = []
    for path in sorted(folder.glob("*.json")):
        try:
            with path.open(encoding="utf-8") as handle:
                data = json.load(handle)
            if isinstance(data, dict) and "samples" not in data and isinstance(data.get("embedding"), list):
                # An older one-sample record: {"name", "embedding", "embedding_model"}.
                data = {**data, "samples": [{"embedding": data["embedding"],
                                             "embedding_model": data.get("embedding_model")}]}
            if not isinstance(data, dict) or not isinstance(data.get("samples"), list):
                raise ValueError("expected name and samples")
            person_name(data.get("name"))
            records.append((path, data))
        except (OSError, ValueError) as error:
            log(f"skipped voiceprint {path.name}: {error}")
    return records


def load_voiceprints(folder: Path, model: str) -> dict[str, list[np.ndarray]]:
    people: dict[str, list[np.ndarray]] = {}
    for path, data in voiceprint_files(folder):
        name = person_name(data["name"])
        for sample in data["samples"]:
            if not isinstance(sample, dict) or sample.get("embedding_model") != model:
                continue
            try:
                vector = unit_vector(sample.get("embedding"))
            except (ValueError, TypeError) as error:
                log(f"skipped sample in {path.name}: {error}")
                continue
            people.setdefault(name, []).append(vector)
    return people


def append_voiceprint(folder: Path, name: str, embedding: Any, model: str) -> Path:
    name = person_name(name)
    vector = unit_vector(embedding).tolist()
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    folder.chmod(0o700)
    matches = [
        (path, data) for path, data in voiceprint_files(folder) if data["name"] == name
    ]
    if len(matches) > 1:
        raise ValueError(
            "multiple voiceprint files have this name; combine them before enrolling"
        )
    if matches:
        path, data = matches[0]
    else:
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:60] or "speaker"
        digest = hashlib.sha256(name.encode("utf-8")).hexdigest()[:10]
        path = folder / f"{slug}-{digest}.json"
        if path.exists() or path.is_symlink():
            raise ValueError("refusing to overwrite an unreadable voiceprint")
        data = {"name": name, "samples": []}
    if path.is_symlink():
        raise ValueError("refusing to write a symlinked voiceprint")
    data["samples"].append(
        {
            "embedding": vector,
            "embedding_model": model,
            "enrolled_at": datetime.now(timezone.utc).isoformat(),
        }
    )
    # Atomic replacement leaves neither a partial file nor a world-readable one.
    fd, temporary = tempfile.mkstemp(prefix=".enroll-", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(data, handle, ensure_ascii=False, allow_nan=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return path


def timestamp(value: str) -> float:
    try:
        parts = value.split(":")
        if not 1 <= len(parts) <= 3:
            raise ValueError
        values = [float(part) for part in parts]
        if any(not math.isfinite(part) or part < 0 for part in values):
            raise ValueError
        if len(values) > 1 and any(part >= 60 for part in values[1:]):
            raise ValueError
        result = 0.0
        for part in values:
            result = result * 60 + part
        return result
    except ValueError as error:
        raise argparse.ArgumentTypeError("use seconds, MM:SS or HH:MM:SS") from error


def enrollment_audio(
    path: Path, channel: str, start: float, end: float | None, ffmpeg: str
) -> np.ndarray:
    if end is not None and end <= start:
        raise ValueError("--to must be later than --from")
    args = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(path.resolve()),
        "-ss",
        str(start),
    ]
    if end is not None:
        args += ["-t", str(end - start)]
    if channel != "mono":
        args += ["-af", "pan=mono|c0=" + ("c0" if channel == "left" else "c1")]
    args += ["-ac", "1", "-ar", str(EMBED_RATE), "-f", "f32le", "pipe:1"]
    return ffmpeg_decode(args, timeout=120)


# --- Online clustering ------------------------------------------------------


@dataclass
class Cluster:
    total: np.ndarray
    count: int = 0
    seconds: float = 0
    pending: list[tuple[float, float]] = field(default_factory=list)
    name: str | None = None

    @property
    def centroid(self) -> np.ndarray:
        return self.total / self.count


class SpeakerClusters:
    def __init__(
        self,
        config: Config,
        people: dict[str, list[np.ndarray]],
        emit: Callable[[dict[str, Any]], None],
    ) -> None:
        self.config, self.people, self.emit = config, people, emit
        self.clusters: list[Cluster] = []
        self.seen: set[tuple[float, float]] = set()
        self.dimension: int | None = None

    def match(self, centroid: np.ndarray) -> str | None:
        scores = []
        for name, samples in self.people.items():
            # Score each person once: two samples of Priya are not two rivals.
            compatible = [
                float(centroid @ vector)
                for vector in samples
                if vector.shape == centroid.shape
            ]
            if compatible:
                scores.append((max(compatible), name))
        scores.sort(reverse=True)
        if not scores or scores[0][0] < self.config.match_threshold:
            return None
        if len(scores) > 1 and scores[0][0] - scores[1][0] < MATCH_MARGIN:
            return None
        return scores[0][1]

    def add(self, embedding: Any, start: float, end: float) -> None:
        vector = unit_vector(embedding)
        if self.dimension is not None and len(vector) != self.dimension:
            raise ValueError("backend changed its embedding dimension")
        if (start, end) in self.seen:
            return
        self.dimension = len(vector)
        self.seen.add((start, end))
        scores = [
            float(vector @ unit_vector(cluster.centroid))
            if np.linalg.norm(cluster.centroid) > 1e-12
            else -math.inf
            for cluster in self.clusters
        ]
        nearest = int(np.argmax(scores)) if scores else None
        if nearest is not None and scores[nearest] >= self.config.cluster_threshold:
            cluster = self.clusters[nearest]
        else:
            cluster = Cluster(np.zeros_like(vector))
            self.clusters.append(cluster)
        cluster.total += vector
        cluster.count += 1
        cluster.seconds += end - start
        cluster.pending.append((start, end))
        if (
            cluster.name is None
            and cluster.seconds >= self.config.min_cluster_seconds
            and np.linalg.norm(cluster.centroid) > 1e-12
        ):
            cluster.name = self.match(unit_vector(cluster.centroid))
        if cluster.name is not None:
            # A published name is permanent: renaming would tie overlap votes in MacCap.
            for span_start, span_end in cluster.pending:
                self.emit(
                    {
                        "type": "speaker",
                        "stem": "system",
                        "start": span_start,
                        "end": span_end,
                        "name": cluster.name,
                    }
                )
            cluster.pending.clear()


class Assist:
    def __init__(
        self,
        config: Config,
        emit: Callable[[dict[str, Any]], None],
        backend_loader: Callable[[str], Backend] = load_backend,
    ) -> None:
        self.config, self.emit, self.backend_loader = config, emit, backend_loader
        self.stopping = threading.Event()
        self.audio: SessionAudio | None = None
        self.backend: Backend | None = None
        self.clusters: SpeakerClusters | None = None
        self.backend_failed = False

    def handle(self, event: dict[str, Any]) -> None:
        kind = event.get("type")
        if kind == "start":
            self.audio, self.clusters = None, None
            directory = event.get("session_dir")
            if not isinstance(directory, str) or not directory.strip():
                raise ValueError("start requires session_dir")
            self.audio = SessionAudio(
                Path(directory).expanduser(), self.config, self.stopping
            )
        elif kind == "line":
            if event.get("stem") != "system":
                return
            start = number(event.get("start"), "line start")
            end = number(event.get("end"), "line end")
            if start < 0 or end <= start:
                raise ValueError("line needs 0 <= start < end")
            if end - start < self.config.min_line_seconds or self.backend_failed:
                return
            if self.audio is None:
                raise ValueError("line received before a valid start")
            if self.clusters is not None and (start, end) in self.clusters.seen:
                return
            samples = self.audio.read(start, end)
            if self.backend is None:
                try:
                    self.backend = self.backend_loader(self.config.backend)
                except Exception:
                    self.backend_failed = True
                    self.emit(
                        {
                            "type": "status",
                            "text": "Speakers: backend unavailable; see log",
                        }
                    )
                    raise
            if self.clusters is None:
                people = load_voiceprints(
                    Path(self.config.voiceprints).expanduser(), self.backend.model
                )
                self.clusters = SpeakerClusters(self.config, people, self.emit)
            if not self.stopping.is_set():
                self.clusters.add(self.backend.embed(samples), start, end)


# --- JSON-lines transport and chaining -------------------------------------


class Emitter:
    """One lock for our JSON and whole child lines. The stream is binary."""

    def __init__(self, stream: Any) -> None:
        self.stream = stream
        self.lock = threading.Lock()
        self.closed = False

    def raw(self, line: bytes) -> None:
        with self.lock:
            if self.closed:
                return
            try:
                self.stream.write(line if line.endswith(b"\n") else line + b"\n")
                self.stream.flush()
            except (OSError, ValueError):
                self.closed = True

    def __call__(self, message: dict[str, Any]) -> None:
        self.raw(
            json.dumps(
                message, ensure_ascii=False, allow_nan=False, separators=(",", ":")
            ).encode("utf-8")
        )

    def close(self) -> None:
        with self.lock:
            self.closed = True


class Relay:
    def __init__(self, command: list[str], emit: Emitter) -> None:
        self.child = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE
        )
        self.pending: queue.Queue[bytes | None] = queue.Queue()
        self.writer = threading.Thread(
            target=self.write, name="assist-child-stdin", daemon=True
        )
        self.reader = threading.Thread(
            target=self.read, args=(emit,), name="assist-child-stdout", daemon=True
        )
        self.writer.start()
        self.reader.start()

    def write(self) -> None:
        try:
            while True:
                line = self.pending.get()
                if line is None:
                    break
                self.child.stdin.write(line)
                self.child.stdin.flush()
        except (OSError, ValueError):
            log("chained assist closed its input")
        finally:
            with contextlib.suppress(OSError, ValueError):
                self.child.stdin.close()

    def read(self, emit: Emitter) -> None:
        try:
            for line in self.child.stdout:
                emit.raw(line)
        except (OSError, ValueError) as error:
            log(f"chained assist output failed: {error}")
        finally:
            self.child.stdout.close()

    def finish(self, deadline: float) -> None:
        try:
            self.child.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            log("chained assist exceeded the shutdown grace period")
            self.child.terminate()
            try:
                self.child.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=0.2)
        self.writer.join(max(0, deadline - time.monotonic()))
        self.reader.join(max(0, deadline - time.monotonic()))


def run(
    assist: Assist,
    stdin: Any,
    emit: Emitter,
    command: list[str] | None = None,
    grace: float = END_GRACE_SECONDS,
) -> int:
    events: queue.Queue[dict[str, Any] | None] = queue.Queue()
    relay = None
    if command:
        try:
            relay = Relay(command, emit)
        except OSError as error:
            log(f"cannot start chained assist: {error}")

    def work() -> None:
        while not assist.stopping.is_set():
            event = events.get()
            if event is None:
                return
            try:
                assist.handle(event)
            except Exception as error:
                # Never let an event, decoder or model failure kill the reader.
                log(f"skipped event: {type(error).__name__}: {error}")

    worker = threading.Thread(target=work, name="speaker-lines", daemon=True)
    worker.start()
    try:
        for raw in stdin:
            if relay:
                relay.pending.put(raw)  # a slow child cannot hold up MacCap's stdin
            try:
                event = json.loads(raw)
                if not isinstance(event, dict):
                    raise ValueError("event must be a JSON object")
            except (ValueError, UnicodeError, RecursionError) as error:
                log(f"skipped malformed input: {type(error).__name__}")
                continue
            if event.get("type") == "end":
                break
            events.put(event)
    finally:
        deadline = time.monotonic() + grace
        events.put(None)
        if relay:
            relay.pending.put(None)
        worker.join(max(0, deadline - time.monotonic()))
        assist.stopping.set()
        if relay:
            relay.finish(deadline)
        emit.close()
    return 0


def arguments(argv: list[str] | None) -> tuple[argparse.Namespace, Config]:
    # Suppressed defaults allow options both before and after the subcommand.
    common = argparse.ArgumentParser(add_help=False, argument_default=argparse.SUPPRESS)
    common.add_argument("--config", help="JSON settings file")
    common.add_argument(
        "--backend", help="speechbrain (default), pyannote or module:attr"
    )
    common.add_argument(
        "--voiceprints", help=f"folder (default: {DEFAULT_VOICEPRINTS})"
    )
    common.add_argument("--ffmpeg", help="ffmpeg executable or absolute path")
    for key in (
        "cluster_threshold",
        "match_threshold",
        "min_line_seconds",
        "min_cluster_seconds",
        "audio_wait_seconds",
    ):
        common.add_argument("--" + key.replace("_", "-"), type=float)
    parser = argparse.ArgumentParser(description=__doc__, parents=[common])
    parser.add_argument(
        "--then",
        nargs=argparse.REMAINDER,
        metavar="CMD",
        help="relay to another assist; this must be the last option",
    )
    subcommands = parser.add_subparsers(dest="command")
    enroll = subcommands.add_parser(
        "enroll", parents=[common], help="append a consenting person's sample"
    )
    enroll.add_argument("name")
    enroll.add_argument("audio", type=Path)
    enroll.add_argument("--channel", choices=("left", "right", "mono"), default="right")
    enroll.add_argument("--from", dest="start", type=timestamp, default=0.0)
    enroll.add_argument("--to", dest="end", type=timestamp)
    subcommands.add_parser(
        "list", parents=[common], help="list people, sample counts and files"
    )
    args = parser.parse_args(argv)
    if args.then == []:
        parser.error("--then requires a command")
    if args.command and args.then is not None:
        parser.error("--then is only for live assist mode")
    values = {}
    if hasattr(args, "config"):
        with Path(args.config).expanduser().open(encoding="utf-8") as handle:
            values = json.load(handle)
        if not isinstance(values, dict):
            raise ValueError("config must be a JSON object")
    values.update(
        {
            key: getattr(args, key)
            for key in Config.__dataclass_fields__
            if hasattr(args, key)
        }
    )
    return args, Config.parse(values)


def main(argv: list[str] | None = None) -> int:
    try:
        args, config = arguments(argv)
        folder = Path(config.voiceprints).expanduser()
        if args.command == "list":
            for path, data in voiceprint_files(folder):
                models: dict[str, int] = {}
                for sample in data["samples"]:
                    if isinstance(sample, dict) and isinstance(
                        sample.get("embedding_model"), str
                    ):
                        model = sample["embedding_model"]
                        models[model] = models.get(model, 0) + 1
                counts = ", ".join(
                    f"{count} × {model}" for model, count in sorted(models.items())
                )
                print(f"{data['name']}\t{counts or 'no samples'}\t{path}")
            return 0
        if args.command == "enroll":
            samples = enrollment_audio(
                args.audio, args.channel, args.start, args.end, config.ffmpeg
            )
            if len(samples) < config.min_line_seconds * EMBED_RATE:
                raise ValueError("enrollment audio is shorter than min_line_seconds")
            with contextlib.redirect_stdout(sys.stderr):
                backend = load_backend(config.backend)
                embedding = backend.embed(samples)
            path = append_voiceprint(folder, args.name, embedding, backend.model)
            print(f"Enrolled {args.name}: {path}")
            return 0
    except Exception as error:
        log(f"{type(error).__name__}: {error}")
        return 2

    emit = Emitter(sys.stdout.buffer)
    # Reserve the protocol stream; model imports/progress prints go to stderr.
    # The emitter keeps the original stream, including in the relay reader.
    sys.stdout = sys.stderr
    status = run(Assist(config, emit), sys.stdin.buffer, emit, args.then)
    if threading.active_count() > 1:
        # A model import/inference may outlive the grace period. Do not block
        # interpreter shutdown or race a daemon's logging during finalization.
        os._exit(status)
    return status


if __name__ == "__main__":
    sys.exit(main())
