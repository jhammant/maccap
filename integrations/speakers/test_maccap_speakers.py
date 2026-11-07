# Copyright (c) 2026 Jonathan Hammant. MIT License: see LICENSE at the repository root.
"""Offline tests: real AAC fixtures and subprocess protocol, no downloaded models."""

import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import wave
from pathlib import Path
from unittest import mock

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import maccap_speakers as ms  # noqa: E402

SCRIPT = HERE / "maccap_speakers.py"
FFMPEG = shutil.which("ffmpeg")
FAKE = "test_maccap_speakers:FakeBackend"


class FakeBackend:
    """Deterministic vectors for low tone, high tone and silence; no ML imports."""

    model = "test/frequency-v1"

    def embed(self, samples):
        if samples.dtype != np.float32 or samples.ndim != 1:
            raise ValueError("expected float32 mono audio")
        if np.max(np.abs(samples)) < 0.001:
            return [0.0, 0.0, 1.0]
        frequency = np.argmax(np.abs(np.fft.rfft(samples))) * 16000 / len(samples)
        return [1.0, 0.0, 0.0] if frequency < 600 else [0.0, 1.0, 0.0]


def event(start=0.0, duration=2.0, stem="system"):
    return {
        "type": "line",
        "stem": stem,
        "start": start,
        "end": start + duration,
        "text": "Priya has an update.",
    }


def wire(events):
    return b"".join(json.dumps(item).encode() + b"\n" for item in events)


def config(**kwargs):
    return ms.Config.parse({"backend": FAKE, **kwargs})


def cli(args, data=b"", timeout=10):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        cwd=HERE,
        check=False,
    )


class TemporaryTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()


class ConfigTests(TemporaryTest):
    def test_backend_defaults_and_flag_overrides(self):
        settings = self.root / "settings.json"
        settings.write_text(
            json.dumps({"backend": "pyannote", "min_cluster_seconds": 8})
        )
        _, parsed = ms.arguments(
            ["--config", str(settings), "--match-threshold", "0.9"]
        )
        self.assertEqual(parsed.cluster_threshold, ms.THRESHOLDS["pyannote"][0])
        self.assertEqual(parsed.match_threshold, 0.9)
        self.assertEqual(parsed.min_cluster_seconds, 8)

    def test_common_options_before_and_after_subcommand(self):
        _, parsed = ms.arguments(
            [
                "--backend",
                FAKE,
                "enroll",
                "Priya Shah",
                "call.m4a",
                "--voiceprints",
                str(self.root),
                "--min-line-seconds",
                "2",
            ]
        )
        self.assertEqual(parsed.backend, FAKE)
        self.assertEqual(parsed.voiceprints, str(self.root))
        self.assertEqual(parsed.min_line_seconds, 2)

    def test_config_rejects_bad_values(self):
        for bad in (
            [],
            {"backend": []},
            {"match_threshold": float("nan")},
            {"cluster_threshold": 2},
            {"min_line_seconds": 0},
            {"audio_wait_seconds": -1},
            {"min_cluster_seconds": True},
            {"ffmpeg": ""},
            {"unknown_key": 1},
        ):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                ms.Config.parse(bad)

    def test_timestamps(self):
        self.assertEqual(ms.timestamp("12:30"), 750)
        self.assertEqual(ms.timestamp("1:02:03.5"), 3723.5)
        self.assertEqual(ms.timestamp("3.25"), 3.25)
        for value in ("nan", "-1", "1:60", "1:2:3:4", "nope"):
            with (
                self.subTest(value=value),
                self.assertRaises(ms.argparse.ArgumentTypeError),
            ):
                ms.timestamp(value)

    def test_bad_config_exits_cleanly(self):
        path = self.root / "bad.json"
        path.write_text("[]")
        result = cli(["--config", str(path)])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"config must be a JSON object", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)


class BackendTests(unittest.TestCase):
    def test_import_is_lazy_and_list_needs_no_model(self):
        code = (
            "import sys; import maccap_speakers as m; "
            "m.arguments(['--backend', 'pyannote', 'list']); "
            "assert not any(k.split('.')[0] in ('torch', 'speechbrain', 'pyannote') "
            "for k in sys.modules)"
        )
        result = subprocess.run(
            [sys.executable, "-c", code], cwd=HERE, capture_output=True
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_custom_class_and_instance(self):
        self.assertEqual(ms.load_backend(FAKE).model, FakeBackend.model)
        module = types.ModuleType("test_custom_speakers")
        module.instance = FakeBackend()
        with mock.patch.dict(sys.modules, {module.__name__: module}):
            self.assertIs(
                ms.load_backend("test_custom_speakers:instance"), module.instance
            )
        with self.assertRaises(ValueError):
            ms.load_backend("not-a-module-spec")

    def test_pyannote_loads_community_embedding_subfolder(self):
        torch = mock.MagicMock()
        api = types.ModuleType("pyannote.audio.pipelines.speaker_verification")
        api.PretrainedSpeakerEmbedding = mock.Mock()
        encoder = api.PretrainedSpeakerEmbedding.return_value
        encoder.return_value = np.array([[1.0, 2.0, 3.0]])
        with (
            mock.patch.dict(sys.modules, {"torch": torch, api.__name__: api}),
            mock.patch.dict(os.environ, {}, clear=True),
        ):
            backend = ms.PyannoteBackend()
            result = backend.embed(np.ones(16000, dtype=np.float32))
            self.assertEqual(os.environ["PYANNOTE_METRICS_ENABLED"], "0")
        api.PretrainedSpeakerEmbedding.assert_called_once_with(
            {"checkpoint": ms.PYANNOTE_MODEL, "subfolder": "embedding"},
            device=torch.device.return_value,
            token=None,
        )
        self.assertEqual(backend.model, ms.PYANNOTE_MODEL)
        self.assertEqual(result, [1.0, 2.0, 3.0])

    def test_speechbrain_uses_ecapa_and_16khz_tensor(self):
        torch = mock.MagicMock()
        api = types.ModuleType("speechbrain.inference.speaker")
        api.EncoderClassifier = mock.Mock()
        encoder = api.EncoderClassifier.from_hparams.return_value
        encoder.encode_batch.return_value.detach.return_value.cpu.return_value.reshape.return_value.tolist.return_value = [
            1.0,
            0.0,
        ]
        with mock.patch.dict(sys.modules, {"torch": torch, api.__name__: api}):
            backend = ms.SpeechBrainBackend()
            samples = np.ones(16000, dtype=np.float32)
            self.assertEqual(backend.embed(samples), [1.0, 0.0])
        self.assertEqual(
            api.EncoderClassifier.from_hparams.call_args.kwargs["source"],
            ms.SPEECHBRAIN_MODEL,
        )
        torch.from_numpy.assert_called_once_with(samples)


class ClusterTests(unittest.TestCase):
    def make_clusters(self, people=None, **settings):
        self.messages = []
        people = (
            people if people is not None else {"Priya Shah": [[1, 0]], "Sam": [[0, 1]]}
        )
        people = {
            name: [ms.unit_vector(sample) for sample in samples]
            for name, samples in people.items()
        }
        self.clusters = ms.SpeakerClusters(
            config(**settings), people, self.messages.append
        )
        return self.clusters

    def test_names_after_six_seconds_and_backfills_once(self):
        clusters = self.make_clusters()
        clusters.add([3, 0], 0, 2)
        clusters.add([1, 0], 3, 5)
        self.assertEqual(self.messages, [])
        clusters.add([10, 0], 6, 8)
        clusters.add([1, 0], 9, 11)
        self.assertEqual(
            [(item["start"], item["end"]) for item in self.messages],
            [(0, 2), (3, 5), (6, 8), (9, 11)],
        )
        self.assertTrue(all(item["name"] == "Priya Shah" for item in self.messages))
        self.assertTrue(all(item["stem"] == "system" for item in self.messages))
        self.assertEqual(clusters.clusters[0].pending, [])

    def test_centroid_means_normalized_embeddings_not_loudness(self):
        clusters = self.make_clusters({}, cluster_threshold=0)
        clusters.add([100, 0], 0, 2)
        clusters.add([0, 1], 2, 4)
        np.testing.assert_allclose(clusters.clusters[0].centroid, [0.5, 0.5])

    def test_nearest_cluster_and_threshold(self):
        clusters = self.make_clusters(min_cluster_seconds=1)
        clusters.add([1, 0], 0, 2)
        clusters.add([0, 1], 2, 4)
        clusters.add([0.1, 1], 4, 6)
        self.assertEqual(len(clusters.clusters), 2)
        self.assertEqual(
            [item["name"] for item in self.messages], ["Priya Shah", "Sam", "Sam"]
        )

    def test_name_never_changes_even_after_centroid_drifts(self):
        clusters = self.make_clusters(min_cluster_seconds=1, cluster_threshold=0)
        clusters.add([1, 0], 0, 2)
        for index in range(1, 10):
            clusters.add([0, 1], index * 2, index * 2 + 2)
        self.assertEqual(
            clusters.match(ms.unit_vector(clusters.clusters[0].centroid)), "Sam"
        )
        self.assertEqual({item["name"] for item in self.messages}, {"Priya Shah"})
        self.assertEqual(len(self.messages), 10)

    def test_unknown_voice_remains_unnamed(self):
        clusters = self.make_clusters()
        for index in range(6):
            clusters.add([-1, -1], index * 2, index * 2 + 2)
        self.assertEqual(self.messages, [])
        self.assertIsNone(clusters.clusters[0].name)

    def test_margin_is_over_next_person_not_next_sample(self):
        clusters = self.make_clusters(
            {"Priya Shah": [[1, 0], [1, 0.01]], "Sam": [[0.99, 0.1]]},
            min_cluster_seconds=1,
        )
        clusters.add([1, 0], 0, 2)
        self.assertEqual(self.messages, [])
        clusters.people.pop("Sam")
        clusters.add([1, 0], 2, 4)
        self.assertEqual(
            [item["name"] for item in self.messages], ["Priya Shah", "Priya Shah"]
        )

    def test_duplicate_span_does_not_accelerate_naming(self):
        clusters = self.make_clusters()
        for _ in range(10):
            clusters.add([1, 0], 0, 2)
        self.assertEqual(self.messages, [])
        self.assertEqual(clusters.clusters[0].seconds, 2)

    def test_invalid_embeddings_and_dimension_changes_are_rejected(self):
        clusters = self.make_clusters()
        for vector in ([], [0, 0], [float("nan"), 1], [float("inf"), 1], [[1, 0]]):
            with self.subTest(vector=vector), self.assertRaises(ValueError):
                clusters.add(vector, 0, 2)
        clusters.add([1, 0], 0, 2)
        with self.assertRaises(ValueError):
            clusters.add([1, 0, 0], 2, 4)
        self.assertEqual(clusters.clusters[0].count, 1)

    def test_incompatible_voiceprint_dimensions_are_ignored(self):
        clusters = self.make_clusters({"Dana": [[1, 0, 0]]}, min_cluster_seconds=1)
        clusters.add([1, 0], 0, 2)
        self.assertEqual(self.messages, [])

    def test_cancelling_vectors_do_not_poison_future_lines(self):
        clusters = self.make_clusters(cluster_threshold=-1)
        clusters.add([1, 0], 0, 3)
        clusters.add([-1, 0], 3, 6)
        self.assertEqual(self.messages, [])
        clusters.add([1, 0], 6, 12)
        self.assertEqual(len(clusters.clusters), 2)
        self.assertEqual([item["name"] for item in self.messages], ["Priya Shah"])


class VoiceprintTests(TemporaryTest):
    def test_append_format_permissions_and_model_filtering(self):
        folder = self.root / "voiceprints"
        path = ms.append_voiceprint(folder, "Priya Shah", [2, 0], FakeBackend.model)
        path.chmod(0o644)
        folder.chmod(0o755)
        other_path = ms.append_voiceprint(folder, "Priya Shah", [0, 1], "another/model")
        self.assertEqual(path, other_path)
        data = json.loads(path.read_text())
        self.assertEqual(set(data), {"name", "samples"})
        self.assertEqual(len(data["samples"]), 2)
        self.assertEqual(
            set(data["samples"][0]), {"embedding", "embedding_model", "enrolled_at"}
        )
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(folder.stat().st_mode), 0o700)
        people = ms.load_voiceprints(folder, FakeBackend.model)
        self.assertEqual(len(people["Priya Shah"]), 1)
        np.testing.assert_equal(people["Priya Shah"][0], [1, 0])
        self.assertEqual(ms.load_voiceprints(folder, "missing/model"), {})

    def test_existing_arbitrary_filename_is_reused(self):
        path = self.root / "priya.json"
        path.write_text(json.dumps({"name": "Priya Shah", "samples": []}))
        self.assertEqual(
            ms.append_voiceprint(self.root, "Priya Shah", [1, 0], "test"), path
        )
        self.assertEqual(len(list(self.root.glob("*.json"))), 1)

    def test_bad_files_and_samples_are_skipped(self):
        (self.root / "bad.json").write_text("{")
        (self.root / "wrong.json").write_text("[]")
        (self.root / "sam.json").write_text(
            json.dumps(
                {
                    "name": "Sam",
                    "samples": [
                        None,
                        {"embedding_model": "test", "embedding": [0, 0]},
                        {"embedding_model": "test", "embedding": [1, 0]},
                    ],
                }
            )
        )
        with mock.patch.object(ms, "log") as log:
            people = ms.load_voiceprints(self.root, "test")
        self.assertEqual(set(people), {"Sam"})
        self.assertEqual(len(people["Sam"]), 1)
        self.assertEqual(log.call_count, 3)

    def test_an_older_one_sample_record_is_read(self):
        (self.root / "alex.json").write_text(
            json.dumps({"name": "Alex", "embedding": [0, 2], "embedding_model": "test"})
        )
        people = ms.load_voiceprints(self.root, "test")
        self.assertEqual(list(people), ["Alex"])
        np.testing.assert_allclose(people["Alex"][0], [0, 1])

    def test_list_does_not_load_backend_and_reports_paths_and_models(self):
        path = ms.append_voiceprint(self.root, "Dana", [1, 0], "test/model")
        result = cli(
            ["list", "--voiceprints", str(self.root), "--backend", "absent:Backend"]
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        output = result.stdout.decode()
        self.assertIn("Dana", output)
        self.assertIn("1 × test/model", output)
        self.assertIn(str(path), output)
        self.assertEqual(result.stderr, b"")

    def test_name_is_not_a_path_and_symlinks_are_refused(self):
        path = ms.append_voiceprint(self.root, "../Alex", [1, 0], "test")
        self.assertEqual(path.parent, self.root)
        target = self.root / "target"
        target.write_text(json.dumps({"name": "Sam", "samples": []}))
        (self.root / "sam.json").symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            ms.append_voiceprint(self.root, "Sam", [1, 0], "test")


@unittest.skipUnless(FFMPEG, "ffmpeg is required for generated AAC fixtures")
class AudioTests(TemporaryTest):
    def setUp(self):
        super().setUp()
        self.aac = self.root / "system-000.aac"
        # FFmpeg's encoder delay differs from Apple's. Mapping tests compare
        # decoded samples, explicitly applying MacCap's documented 2112 offset.
        result = subprocess.run(
            [
                FFMPEG,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "aevalsrc=0.3*sin(2*PI*(200*t+20*t*t)):s=48000:d=8",
                "-ac",
                "1",
                "-c:a",
                "aac",
                "-b:a",
                "96k",
                "-f",
                "adts",
                str(self.aac),
            ],
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.data = self.aac.read_bytes()
        self.manifest([{"file": self.aac.name, "start_seconds": 0.0}])
        self.audio = ms.SessionAudio(
            self.root, config(ffmpeg=FFMPEG, audio_wait_seconds=0), threading.Event()
        )

    def manifest(self, segments):
        (self.root / "session.json").write_text(
            json.dumps({"system_segments": segments})
        )

    def test_frame_index_matches_full_decoded_sample_count_and_is_cached(self):
        index = ms.ADTSIndex(self.aac)
        index.extend()
        decoded = ms.ffmpeg_decode(
            [
                FFMPEG,
                "-v",
                "error",
                "-f",
                "aac",
                "-i",
                "pipe:0",
                "-f",
                "f32le",
                "pipe:1",
            ],
            self.data,
        )
        self.assertEqual(len(decoded), index.frames * 1024)
        self.assertEqual(index.boundaries[-1], len(self.data))
        boundaries = list(index.boundaries)
        # Growing segments are append-only. Changing an already indexed header
        # proves that a later extension does not rescan old frames.
        with self.aac.open("r+b") as handle:
            handle.write(b"\x00")
        index.extend()
        self.assertEqual(index.boundaries, boundaries)
        first, _ = self.audio.segment(0, 1)
        second, _ = self.audio.segment(1, 2)
        self.assertIs(first, second)

    def test_truncated_last_header_and_payload_then_growing_file(self):
        complete = ms.ADTSIndex(self.aac)
        complete.extend()
        index = ms.ADTSIndex(self.aac)
        last = complete.boundaries[-2]
        self.aac.write_bytes(self.data[: last + 3])
        index.extend()
        self.assertEqual(index.frames, complete.frames - 1)
        with self.aac.open("ab") as handle:
            handle.write(self.data[last + 3 : -1])
        index.extend()
        self.assertEqual(index.frames, complete.frames - 1)
        with self.aac.open("ab") as handle:
            handle.write(self.data[-1:])
        index.extend()
        self.assertEqual(index.boundaries, complete.boundaries)

    def test_crc_header_and_invalid_frame(self):
        index = ms.ADTSIndex(self.aac)
        index.extend()
        frame = bytearray(self.data[: index.boundaries[1]])
        frame[1] &= 0xFE
        length = len(frame) + 2
        frame[3] = (frame[3] & 0xFC) | (length >> 11)
        frame[4] = (length >> 3) & 0xFF
        frame[5] = (frame[5] & 0x1F) | ((length & 7) << 5)
        frame[7:7] = b"\x00\x00"
        self.aac.write_bytes(frame)
        index.extend()
        self.assertEqual(index.frames, 1)
        self.assertEqual(index.boundaries[-1], len(frame))
        self.aac.write_bytes(b"not adts")
        with self.assertRaisesRegex(ValueError, "ADTS sync"):
            index.extend()

    def test_priming_mapping_and_exact_span_against_full_decode(self):
        offset = 12.5
        self.manifest([{"file": self.aac.name, "start_seconds": offset}])
        full = ms.ffmpeg_decode(
            [
                FFMPEG,
                "-v",
                "error",
                "-f",
                "aac",
                "-i",
                "pipe:0",
                "-ac",
                "1",
                "-ar",
                "16000",
                "-f",
                "f32le",
                "pipe:1",
            ],
            self.data,
        )
        for local_start in (0.0, 0.513, 3.117):
            with self.subTest(local_start=local_start):
                start, end = offset + local_start, offset + local_start + 1.25
                samples = self.audio.read(start, end)
                expected_start = round(local_start * 16000 + 2112 / 3)
                expected = full[expected_start : expected_start + 20000]
                self.assertEqual(samples.shape, (20000,))
                self.assertEqual(samples.dtype, np.float32)
                # Slicing resets the resampler phase by at most one output sample.
                self.assertGreater(np.corrcoef(samples, expected)[0, 1], 0.99)
                wrong = full[
                    round(local_start * 16000) : round(local_start * 16000) + 20000
                ]
                self.assertLess(abs(np.corrcoef(samples, wrong)[0, 1]), 0.5)

    def test_decode_reads_only_requested_frames_with_two_frame_margins(self):
        with mock.patch.object(ms, "ffmpeg_decode", wraps=ms.ffmpeg_decode) as decode:
            self.audio.read(3, 4)
        selected = decode.call_args.args[1]
        self.assertLess(len(selected), len(self.data) / 3)
        index = self.audio.indexes[self.aac]
        first = int((3 * 48000 + 2112) // 1024) - 2
        self.assertTrue(self.data[index.boundaries[first] :].startswith(selected))

    def test_waits_for_audio_to_grow_and_times_out_if_it_does_not(self):
        complete = ms.ADTSIndex(self.aac)
        complete.extend()
        prefix = complete.boundaries[25]
        self.aac.write_bytes(self.data[:prefix])
        self.audio.config.audio_wait_seconds = 1

        def append():
            with self.aac.open("ab") as handle:
                handle.write(self.data[prefix:])

        timer = threading.Timer(0.15, append)
        timer.start()
        self.addCleanup(timer.join)
        samples = self.audio.read(0, 2)
        self.assertEqual(len(samples), 32000)
        self.audio.config.audio_wait_seconds = 0.02
        with self.assertRaises(ms.AudioPending):
            self.audio.read(20, 22)

    def test_new_segment_manifest_and_boundary_spans(self):
        next_file = self.root / "system-001.aac"
        next_file.write_bytes(self.data)
        self.manifest(
            [
                {"file": self.aac.name, "start_seconds": 0},
                {"file": next_file.name, "start_seconds": 10},
            ]
        )
        self.assertEqual(self.audio.segment(11, 12)[0].path, next_file)
        self.assertEqual(len(self.audio.read(11, 12)), 16000)
        with self.assertRaisesRegex(ValueError, "crosses"):
            self.audio.read(9, 11)

    def test_segment_path_cannot_escape_session(self):
        self.manifest([{"file": "../outside.aac", "start_seconds": 0}])
        with self.assertRaisesRegex(ValueError, "inside session_dir"):
            self.audio.read(0, 1)

    def test_enroll_cli_right_left_time_selection_append_and_list(self):
        path = self.root / "call.wav"
        times = np.arange(16000 * 3) / 16000
        left = np.sin(2 * np.pi * 440 * times)
        right = np.sin(2 * np.pi * np.where(times < 1, 440, 880) * times)
        pcm = (np.stack([left, right], axis=1) * 15000).astype("<i2")
        with wave.open(str(path), "wb") as handle:
            handle.setnchannels(2)
            handle.setsampwidth(2)
            handle.setframerate(16000)
            handle.writeframes(pcm.tobytes())
        recording = self.root / "call.m4a"
        encoded = subprocess.run(
            [FFMPEG, "-v", "error", "-i", str(path), "-c:a", "aac", str(recording)],
            capture_output=True,
        )
        self.assertEqual(encoded.returncode, 0, encoded.stderr.decode())
        folder = self.root / "prints"
        for channel in ("right", "left"):
            result = cli(
                [
                    "enroll",
                    "Priya Shah",
                    str(recording),
                    "--channel",
                    channel,
                    "--from",
                    "0:01",
                    "--to",
                    "0:02.5",
                    "--backend",
                    FAKE,
                    "--ffmpeg",
                    FFMPEG,
                    "--voiceprints",
                    str(folder),
                ]
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        data = json.loads(next(folder.glob("*.json")).read_text())
        self.assertEqual(
            [sample["embedding"] for sample in data["samples"]], [[0, 1, 0], [1, 0, 0]]
        )
        listing = cli(["list", "--voiceprints", str(folder)])
        self.assertIn("2 × test/frequency-v1", listing.stdout.decode())

    def test_live_cli_backfills_system_and_ignores_mic_and_short_lines(self):
        folder = self.root / "prints"
        ms.append_voiceprint(folder, "Priya Shah", [1, 0, 0], FakeBackend.model)
        events = [
            {"type": "start", "session_dir": str(self.root)},
            event(0, stem="mic"),
            event(0, duration=0.25),
            event(0),
            event(2),
            event(4),
            {"type": "end"},
        ]
        result = cli(
            ["--backend", FAKE, "--voiceprints", str(folder), "--ffmpeg", FFMPEG],
            wire(events),
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        messages = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(messages), 3, result.stderr.decode())
        self.assertEqual([item["start"] for item in messages], [0, 2, 4])
        self.assertEqual({item["name"] for item in messages}, {"Priya Shah"})
        self.assertEqual({item["stem"] for item in messages}, {"system"})

    def test_live_speaker_messages_and_child_lines_share_stdout(self):
        folder = self.root / "prints"
        ms.append_voiceprint(folder, "Priya Shah", [1, 0, 0], FakeBackend.model)
        child = self.root / "child.py"
        child.write_text(
            "import sys, time\n"
            "for line in sys.stdin.buffer:\n"
            '    sys.stdout.write(\'{"type":"status",\')\n'
            "    sys.stdout.flush()\n"
            "    time.sleep(0.02)\n"
            '    sys.stdout.write(\'"text":"Sam"}\\n\')\n'
            "    sys.stdout.flush()\n"
        )
        events = [
            {"type": "start", "session_dir": str(self.root)},
            event(0),
            event(2),
            event(4),
            {"type": "end"},
        ]
        result = cli(
            [
                "--backend",
                FAKE,
                "--voiceprints",
                str(folder),
                "--ffmpeg",
                FFMPEG,
                "--then",
                sys.executable,
                str(child),
            ],
            wire(events),
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        messages = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(sum(item["type"] == "speaker" for item in messages), 3)
        self.assertEqual(sum(item["type"] == "status" for item in messages), 5)


class ProtocolTests(TemporaryTest):
    def test_end_exits_while_stdin_stays_open(self):
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            process.stdin.write(b'{"type":"end"}\n')
            process.stdin.flush()
            self.assertEqual(process.wait(timeout=2), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def test_bad_input_does_not_crash_and_valid_events_still_work(self):
        output = io.BytesIO()
        emit = ms.Emitter(output)
        assist = ms.Assist(config(), emit)
        messages = b"not json\n[]\nnull\n\xff\n" + wire(
            [
                {"type": "start"},
                event(),
                {"type": "start", "session_dir": str(self.root)},
                event(float("nan")),
                event(duration=-1),
                event(stem="mic"),
                {"type": "line", "stem": "system", "start": "1", "end": 3},
                {"type": "ask", "question": "Sam?"},
                {"type": "end"},
            ]
        )
        with mock.patch.object(ms, "log") as log:
            status = ms.run(assist, io.BytesIO(messages), emit)
        self.assertEqual(status, 0)
        self.assertIsNotNone(assist.audio)
        self.assertGreaterEqual(log.call_count, 9)
        self.assertEqual(output.getvalue(), b"")

    def test_stdin_is_consumed_while_worker_is_blocked(self):
        entered, release, consumed = (
            threading.Event(),
            threading.Event(),
            threading.Event(),
        )
        emit = ms.Emitter(io.BytesIO())
        assist = ms.Assist(config(), emit)

        def blocked(event):
            entered.set()
            release.wait(2)

        assist.handle = blocked

        def stream():
            yield b'{"type":"start"}\n'
            self.assertTrue(entered.wait(1))
            yield b'{"type":"ask"}\n'
            consumed.set()
            yield b'{"type":"end"}\n'

        runner = threading.Thread(target=ms.run, args=(assist, stream(), emit))
        runner.start()
        try:
            self.assertTrue(consumed.wait(1), "stdin was held up by the worker")
        finally:
            release.set()
            runner.join(2)
        self.assertFalse(runner.is_alive())

    def test_mic_short_and_bad_lines_never_load_model(self):
        loader = mock.Mock()
        assist = ms.Assist(config(), lambda _: None, loader)
        assist.handle({"type": "start", "session_dir": str(self.root)})
        assist.handle(event(stem="mic"))
        assist.handle(event(duration=0.99))
        loader.assert_not_called()

    def test_backend_failure_reported_once_and_worker_keeps_running(self):
        messages = []
        loader = mock.Mock(side_effect=RuntimeError("unavailable"))
        assist = ms.Assist(config(), messages.append, loader)
        assist.audio = mock.Mock()
        assist.audio.read.return_value = np.ones(32000, dtype=np.float32)
        with self.assertRaises(RuntimeError):
            assist.handle(event())
        assist.handle(event(2))
        self.assertEqual(loader.call_count, 1)
        self.assertEqual([item["type"] for item in messages], ["status"])

    def test_thread_safe_whole_lines_and_flush(self):
        stream = mock.Mock(wraps=io.BytesIO())
        emit = ms.Emitter(stream)

        def own():
            for _ in range(100):
                emit({"type": "speaker", "name": "Dana" * 1000})

        def child():
            for _ in range(100):
                emit.raw(b'{"type":"status","text":"Sam"}\n')

        threads = [threading.Thread(target=own), threading.Thread(target=child)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(len(stream.getvalue().splitlines()), 200)
        self.assertTrue(
            all(
                isinstance(json.loads(line), dict)
                for line in stream.getvalue().splitlines()
            )
        )
        self.assertEqual(stream.flush.call_count, 200)

    def child(self, source):
        path = self.root / "child.py"
        path.write_text(source)
        return [sys.executable, str(path)]

    def test_then_forwards_exact_input_and_child_stdout_stderr_on_end_and_eof(self):
        received = self.root / "received.bin"
        command = self.child(
            "import pathlib, sys\n"
            "data = sys.stdin.buffer.read()\n"
            "pathlib.Path(sys.argv[1]).write_bytes(data)\n"
            'sys.stdout.write(\'{"type":"status","text":"Sam"}\\n\')\n'
            'sys.stdout.write(\'{"type":"status","text":"Dana"}\')\n'
            "sys.stderr.write('child diagnostic\\n')\n"
        ) + [str(received)]
        for ending in (b'{"type":"end"}\n', b""):
            with self.subTest(ending=ending):
                data = b' {"type": "ask", "question":"Alex?"} \r\n\xffbad\n\n' + ending
                result = cli(["--then", *command], data)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(received.read_bytes(), data)
                self.assertEqual(
                    result.stdout,
                    b'{"type":"status","text":"Sam"}\n'
                    b'{"type":"status","text":"Dana"}\n',
                )
                self.assertIn(b"child diagnostic", result.stderr)

    def test_slow_child_input_does_not_block_reader_and_is_terminated(self):
        command = self.child("import time\ntime.sleep(30)\n")
        emit = ms.Emitter(io.BytesIO())
        assist = ms.Assist(config(), emit)
        data = wire([{"type": "ask", "question": "x" * 200000}, {"type": "end"}])
        started = time.monotonic()
        with mock.patch.object(ms, "log"):
            ms.run(assist, io.BytesIO(data), emit, command, grace=0.2)
        self.assertLess(time.monotonic() - started, 1.5)

    def test_child_exit_and_missing_executable_are_not_fatal(self):
        for command in (
            ["/does-not-exist-speakers-test"],
            self.child("raise SystemExit(0)\n"),
        ):
            with self.subTest(command=command), mock.patch.object(ms, "log"):
                emit = ms.Emitter(io.BytesIO())
                status = ms.run(
                    ms.Assist(config(), emit),
                    io.BytesIO(wire([event(), {"type": "end"}])),
                    emit,
                    command,
                )
                self.assertEqual(status, 0)

    def test_backend_stdout_is_kept_off_protocol_stream(self):
        # Import-time chatter is also redirected; no actual audio/model needed.
        backend = self.root / "noisy.py"
        backend.write_text(
            "print('model progress')\nraise RuntimeError('test backend')\n"
        )
        code = (
            "import sys, numpy as np; import maccap_speakers as m; "
            "m.SessionAudio.read = lambda *args: np.ones(16000, dtype=np.float32); "
            "raise SystemExit(m.main(['--backend', 'noisy:Backend']))"
        )
        env = dict(os.environ, PYTHONPATH=str(self.root))
        result = subprocess.run(
            [sys.executable, "-c", code],
            cwd=HERE,
            env=env,
            input=wire(
                [
                    {"type": "start", "session_dir": str(self.root)},
                    event(),
                    {"type": "end"},
                ]
            ),
            capture_output=True,
            timeout=8,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)["type"], "status")
        self.assertIn(b"model progress", result.stderr)


if __name__ == "__main__":
    unittest.main()
