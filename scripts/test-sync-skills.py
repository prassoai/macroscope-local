#!/usr/bin/env python3
"""Disposable sync acceptance tests; source repositories are read-only.

python3 scripts/test-sync-skills.py --back-repo /path/to/back --ref FULL_SHA \
    [--legacy-repo /path/to/macroscope-local --legacy-ref FULL_SHA]
"""
import argparse
import contextlib
import errno
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import types
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("sync-skills-from-back.sh")
PYTHON_SOURCE = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
SYNC = types.ModuleType("macroscope_sync")
exec(compile(PYTHON_SOURCE, str(SCRIPT), "exec"), SYNC.__dict__)
OPTIONS = None


def command(repo, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    return subprocess.check_output(["git", "-C", str(repo), *args], env=env, stderr=subprocess.PIPE)


def export_committed(repo, ref, prefix, destination):
    names = command(repo, "ls-tree", "-r", "--name-only", ref, "--", prefix).decode().splitlines()
    for name in names:
        relative = Path(name).relative_to(prefix) if prefix else Path(name)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(command(repo, "show", f"{ref}:{name}"))


def commit_fixture(repo):
    command(repo, "add", "--all")
    command(repo, "-c", "user.name=Sync Fixture", "-c", "user.email=sync-fixture@example.invalid",
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture")
    return command(repo, "rev-parse", "HEAD").decode().strip()


def snapshot(root):
    result = {}
    for path in sorted(root.rglob("*")):
        key = str(path.relative_to(root))
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            result[key] = ("symlink", mode, os.readlink(path))
        elif path.is_dir():
            result[key] = ("directory", mode)
        else:
            result[key] = ("file", mode, path.read_bytes())
    return result


class SyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.suite_tmp = tempfile.TemporaryDirectory(prefix="macroscope-sync-tests-")
        cls.suite_root = Path(cls.suite_tmp.name)
        cls.candidate = cls.suite_root / "candidate-bundle"
        export_committed(OPTIONS.back_repo, OPTIONS.ref, SYNC.SOURCE_PREFIX, cls.candidate)
        if OPTIONS.legacy_ref:
            cls.legacy = cls.suite_root / "legacy-bundle"
            for prefix in (".claude-plugin", "plugins/macroscope"):
                export_committed(OPTIONS.legacy_repo, OPTIONS.legacy_ref, prefix, cls.legacy / prefix)

    @classmethod
    def tearDownClass(cls):
        cls.suite_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=self.suite_root, prefix="case-")
        self.root = Path(self.tmp.name)
        self.output = self.root / "destination with spaces\tand-tab"
        self.output.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def sync(self, output=None, repo=None, ref=None):
        with contextlib.redirect_stdout(io.StringIO()):
            SYNC.sync(repo or OPTIONS.back_repo, ref or OPTIONS.ref, output or self.output)

    def fixture(self, bundle=None):
        repo = self.root / "fixture-back"
        repo.mkdir()
        command(repo, "init", "-q")
        source = repo / SYNC.SOURCE_PREFIX
        shutil.copytree(bundle or self.candidate, source)
        return repo, source, commit_fixture(repo)

    def seed_owned_and_foreign(self, output=None):
        output = output or self.output
        self.sync(output=output)
        (output / "plugins/foreign").mkdir()
        (output / "plugins/foreign/keep.txt").write_bytes(b"foreign plugin\x00bytes")
        (output / "skills/foreign").mkdir()
        (output / "skills/foreign/SKILL.md").write_text("foreign skill")
        (output / "skills/codereview/keep.txt").write_text("extra skill resource")
        (output / "plugins/macroscope/README.md").write_text("old owned plugin bytes")
        (output / "skills/codereview/SKILL.md").write_text(
            (output / "skills/codereview/SKILL.md").read_text() + "\nold owned skill bytes\n")
        market = output / ".claude-plugin/marketplace.json"
        data = json.loads(market.read_text())
        data["custom"] = {"keep": True}
        data["plugins"].append({"name": "foreign", "source": "./plugins/foreign", "custom": [1, 2]})
        market.write_text(json.dumps(data))
        market.chmod(0o640)

    def test_cli_requires_pin_and_accepts_disposable_output(self):
        missing = subprocess.run(["bash", str(SCRIPT), OPTIONS.back_repo, "--output", str(self.output)],
                                 capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(snapshot(self.output), {})
        result = subprocess.run(["bash", str(SCRIPT), OPTIONS.back_repo, "--ref", OPTIONS.ref,
                                 "--output", str(self.output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(OPTIONS.ref, result.stdout)
        self.assertIn("plugin 2.0.0", result.stdout)

    def test_full_candidate_tree_and_new_skill_contract_are_preserved(self):
        self.sync()
        for source in (self.candidate / "plugins/macroscope").rglob("*"):
            if source.is_file():
                self.assertEqual(source.read_bytes(), (self.output / source.relative_to(self.candidate)).read_bytes())
        for name in ("codereview", "autoloop"):
            source_bytes = (self.candidate / "plugins/macroscope/skills" / name / "SKILL.md").read_bytes()
            generated_bytes = (self.output / "skills" / name / "SKILL.md").read_bytes()
            generated = generated_bytes.decode("utf-8")
            body_bytes = source_bytes.split(b"---", 2)[2].lstrip(b"\r\n")
            self.assertTrue(generated_bytes.endswith(body_bytes))
            self.assertEqual(generated.count(SYNC.PREREQ), 1)
            self.assertEqual(generated.count(SYNC.GENERATED_MARKER), 1)
            self.assertNotIn(OPTIONS.ref, generated)
            self.assertIn("macroscope update --yes", generated)
            self.assertIn("--isolate", generated)
            self.assertIn("--auto-update", generated)
        self.assertIn("**report-only**", (self.output / "skills/codereview/SKILL.md").read_text())

    def test_preserves_foreign_content_and_is_byte_idempotent(self):
        self.seed_owned_and_foreign()
        self.sync()
        first = snapshot(self.output)
        self.sync()
        self.assertEqual(first, snapshot(self.output))
        self.assertEqual((self.output / "plugins/foreign/keep.txt").read_bytes(), b"foreign plugin\x00bytes")
        self.assertEqual((self.output / "skills/foreign/SKILL.md").read_text(), "foreign skill")
        self.assertEqual((self.output / "skills/codereview/keep.txt").read_text(), "extra skill resource")
        market = json.loads((self.output / ".claude-plugin/marketplace.json").read_text())
        self.assertEqual(market["custom"], {"keep": True})
        self.assertIn({"name": "foreign", "source": "./plugins/foreign", "custom": [1, 2]}, market["plugins"])

    def test_legacy_151_contract_then_upgrade_to_200(self):
        if not OPTIONS.legacy_ref:
            self.skipTest("pass --legacy-repo and --legacy-ref for the committed 1.5.1 fixture")
        repo, source, ref = self.fixture(self.legacy)
        self.sync(repo=repo, ref=ref)
        old = (self.output / "skills/codereview/SKILL.md").read_text()
        self.assertIn("--in-place", old)
        self.assertNotIn("macroscope update --yes", old)
        self.assertEqual(json.loads((source / "plugins/macroscope/.claude-plugin/plugin.json").read_text())["version"], "1.5.1")
        # Legacy standalone files lacked the generated ownership comment.
        for name in ("codereview", "autoloop"):
            skill = self.output / "skills" / name / "SKILL.md"
            skill.write_text("\n".join(line for line in skill.read_text().split("\n")
                                      if not line.startswith(SYNC.GENERATED_MARKER)))
        self.sync()
        self.assertIn("macroscope update --yes", (self.output / "skills/codereview/SKILL.md").read_text())
        self.assertNotIn("--in-place", (self.output / "skills/codereview/SKILL.md").read_text())

    def test_dirty_source_is_ignored(self):
        repo, source, ref = self.fixture()
        (source / "plugins/macroscope/skills/codereview/SKILL.md").write_text("uncommitted invalid input")
        self.sync(repo=repo, ref=ref)
        self.assertEqual((self.output / "plugins/macroscope/skills/codereview/SKILL.md").read_bytes(),
                         (self.candidate / "plugins/macroscope/skills/codereview/SKILL.md").read_bytes())

    def test_rejects_moving_ref(self):
        with self.assertRaisesRegex(ValueError, "full 40-character"):
            self.sync(ref="HEAD")
        self.assertEqual(snapshot(self.output), {})

    def test_late_invalid_source_skill_does_not_mutate_any_target(self):
        repo, source, _ = self.fixture()
        (source / "plugins/macroscope/skills/codereview/SKILL.md").write_text("not frontmatter")
        ref = commit_fixture(repo)
        self.seed_owned_and_foreign()
        before = snapshot(self.output)
        with self.assertRaisesRegex(ValueError, "frontmatter"):
            self.sync(repo=repo, ref=ref)
        self.assertEqual(before, snapshot(self.output))

    def test_missing_host_asset_is_rejected_before_apply(self):
        repo, source, _ = self.fixture()
        (source / "plugins/macroscope/host-overlays/codex/skills/autoloop/SKILL.md").unlink()
        ref = commit_fixture(repo)
        with self.assertRaises(FileNotFoundError):
            self.sync(repo=repo, ref=ref)
        self.assertEqual(snapshot(self.output), {})

    def test_manifest_version_mismatch_is_rejected(self):
        repo, source, _ = self.fixture()
        path = source / "plugins/macroscope/.cursor-plugin/plugin.json"
        data = json.loads(path.read_text())
        data["version"] = "0.0.1"
        path.write_text(json.dumps(data))
        ref = commit_fixture(repo)
        with self.assertRaisesRegex(ValueError, "disagree"):
            self.sync(repo=repo, ref=ref)
        self.assertEqual(snapshot(self.output), {})

    def test_source_symlink_is_rejected(self):
        repo, source, _ = self.fixture()
        (source / "plugins/macroscope/escape").symlink_to("../../../../outside")
        ref = commit_fixture(repo)
        with self.assertRaisesRegex(ValueError, "unsupported source archive entry"):
            self.sync(repo=repo, ref=ref)
        self.assertEqual(snapshot(self.output), {})

    def test_unowned_skill_collision_is_preserved(self):
        path = self.output / "skills/codereview"
        path.mkdir(parents=True)
        (path / "SKILL.md").write_text("---\nname: codereview\n---\nForeign review skill")
        before = snapshot(self.output)
        with self.assertRaisesRegex(ValueError, "unowned standalone"):
            self.sync()
        self.assertEqual(before, snapshot(self.output))

    def test_unowned_plugin_collision_is_preserved(self):
        path = self.output / "plugins/macroscope/.claude-plugin"
        path.mkdir(parents=True)
        (path / "plugin.json").write_text('{"name":"macroscope","repository":"https://example.invalid/foreign"}')
        before = snapshot(self.output)
        with self.assertRaisesRegex(ValueError, "unowned plugin"):
            self.sync()
        self.assertEqual(before, snapshot(self.output))

    def test_foreign_marketplace_source_is_preserved(self):
        path = self.output / ".claude-plugin"
        path.mkdir()
        (path / "marketplace.json").write_text(json.dumps({"name": "macroscope-local", "plugins": [
            {"name": "macroscope", "source": "https://example.invalid/foreign"}]}))
        before = snapshot(self.output)
        with self.assertRaisesRegex(ValueError, "foreign source"):
            self.sync()
        self.assertEqual(before, snapshot(self.output))

    def test_destination_parent_symlink_is_not_followed(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "sentinel").write_text("untouched")
        (self.output / "plugins").symlink_to(outside, target_is_directory=True)
        before = snapshot(self.root)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.sync()
        self.assertEqual(before, snapshot(self.root))

    def test_destination_swapped_for_a_symlink_after_validation_cannot_escape(self):
        """check_target compares pathnames, and a pathname cannot bind the inode
        that a later rename resolves. A concurrent writer that replaces an
        already-approved destination parent with a symlink must not redirect the
        replacement outside --output, so the publish walks O_NOFOLLOW directory
        descriptors instead of re-resolving the path."""
        self.seed_owned_and_foreign()
        market = self.output / ".claude-plugin/marketplace.json"
        market_before = market.read_bytes()
        outside = self.root / "outside"
        (outside / "macroscope").mkdir(parents=True)
        outside_before = snapshot(outside)
        original = SYNC.fsync_tree

        def swap_after_validation(path):
            # prepare_targets and every check_target call have completed and no
            # rename has run: exactly the window the pathname check cannot cover.
            shutil.rmtree(self.output / "plugins")
            (self.output / "plugins").symlink_to(outside, target_is_directory=True)
            return original(path)

        with mock.patch.object(SYNC, "fsync_tree", side_effect=swap_after_validation):
            with self.assertRaises(OSError) as caught:
                self.sync()
        # O_DIRECTORY|O_NOFOLLOW over a symlink is ELOOP on macOS and ENOTDIR on
        # Linux; both are the refusal, and neither is a followed symlink.
        self.assertIn(caught.exception.errno, (errno.ELOOP, errno.ENOTDIR))
        self.assertEqual(outside_before, snapshot(outside))
        self.assertEqual(market_before, market.read_bytes())

    def test_every_new_directory_entry_is_flushed_before_it_is_relied_on(self):
        """Power loss during apply must not lose the previous bundle. Every
        directory receiving an entry is fsynced, and so is every staged file:
        a durable directory entry over unwritten data is still data loss.
        os.replace preserves inodes, so a staged file flushed before its rename
        is identifiable at its published path."""
        flushed = []
        original = os.fsync

        def record(fd):
            flushed.append(os.fstat(fd).st_ino)
            return original(fd)

        with mock.patch.object(SYNC.os, "fsync", side_effect=record):
            self.sync()
        self.assertIn(self.output.stat().st_ino, flushed, "output gained plugins/, skills/")
        for relative in (".claude-plugin", "plugins", "skills", "plugins/macroscope/assets",
                         ".claude-plugin/marketplace.json", "plugins/macroscope/README.md",
                         "skills/codereview/SKILL.md"):
            self.assertIn((self.output / relative).stat().st_ino, flushed, relative)

    def test_foreign_skill_quoting_the_prerequisite_is_not_treated_as_owned(self):
        """Ownership is the marker's position, not its presence anywhere in the
        file. A foreign skill that documents the same CLI prerequisite is not a
        previous output of this script and must never be overwritten."""
        path = self.output / "skills/codereview"
        path.mkdir(parents=True)
        (path / "SKILL.md").write_text("---\nname: codereview\ndescription: House review process.\n---\n"
                                       "Run our own review checklist.\n\n" + SYNC.PREREQ)
        before = snapshot(self.output)
        with self.assertRaisesRegex(ValueError, "unowned standalone"):
            self.sync()
        self.assertEqual(before, snapshot(self.output))

    def test_marker_free_legacy_layout_stays_owned_for_migration(self):
        """The bundle that produced today's public checkout predates the
        generated marker and leads with the prerequisite block instead.
        Requiring both markers would fail the first migration sync onto that
        checkout, so the legacy shape has to remain owned."""
        self.sync()
        for name in ("codereview", "autoloop"):
            skill = self.output / "skills" / name / "SKILL.md"
            frontmatter, body = SYNC.skill_frontmatter(skill, name)
            skill.write_text(frontmatter + "\n" + body.split(SYNC.GENERATED_MARKER, 1)[1].lstrip("\r\n"))
            self.assertNotIn(SYNC.GENERATED_MARKER, skill.read_text())
            self.assertTrue(skill.read_text().split("---\n", 2)[2].lstrip("\r\n").startswith(SYNC.PREREQ))
        self.sync()
        self.assertIn(SYNC.GENERATED_MARKER, (self.output / "skills/codereview/SKILL.md").read_text())

    def test_generation_failure_preserves_every_target(self):
        self.seed_owned_and_foreign()
        before = snapshot(self.output)
        original = shutil.copy2

        def fail_generation(source, target, *args, **kwargs):
            if str(target).endswith("skill-codereview/SKILL.md"):
                raise OSError("simulated staging disk failure")
            return original(source, target, *args, **kwargs)

        with mock.patch.object(SYNC.shutil, "copy2", side_effect=fail_generation):
            with self.assertRaisesRegex(OSError, "staging disk"):
                self.sync()
        self.assertEqual(before, snapshot(self.output))

    def test_failures_before_and_after_each_rename_restore_existing_targets(self):
        self.check_rename_failures(existing=True)

    def test_failures_before_and_after_each_rename_restore_empty_destination(self):
        self.check_rename_failures(existing=False)

    def check_rename_failures(self, existing):
        for fail_at in range(1, 9 if existing else 5):
            for after in (False, True):
                with self.subTest(rename=fail_at, after_syscall=after, existing=existing):
                    output = self.root / f"failure-{fail_at}-{after}"
                    output.mkdir()
                    if existing:
                        self.seed_owned_and_foreign(output)
                    before = snapshot(output)
                    original = os.replace
                    calls = 0

                    def injected(source, target, **directories):
                        nonlocal calls
                        calls += 1
                        if calls == fail_at:
                            if after:
                                original(source, target, **directories)
                            raise OSError("simulated apply failure")
                        return original(source, target, **directories)

                    with mock.patch.object(SYNC.os, "replace", side_effect=injected):
                        with self.assertRaisesRegex(OSError, "simulated apply"):
                            self.sync(output=output)
                    self.assertEqual(before, snapshot(output))

    def test_handled_signals_restore_existing_targets(self):
        self.seed_owned_and_foreign()
        before = snapshot(self.output)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                original = os.replace
                calls = 0

                def interrupted_replace(source, target, **directories):
                    nonlocal calls
                    calls += 1
                    original(source, target, **directories)
                    if calls == 3:
                        os.kill(os.getpid(), sig)

                old_handler = signal.signal(sig, SYNC.interrupted)
                try:
                    with mock.patch.object(SYNC.os, "replace", side_effect=interrupted_replace):
                        with self.assertRaisesRegex(InterruptedError, "interrupted by signal"):
                            self.sync()
                finally:
                    signal.signal(sig, old_handler)
                self.assertEqual(before, snapshot(self.output))

    def test_restore_failure_keeps_original_backups_and_blocks_next_sync(self):
        self.seed_owned_and_foreign()
        original_market = (self.output / ".claude-plugin/marketplace.json").read_bytes()
        original = os.replace

        # Renames are directory-relative now, so match the publish of the staged
        # plugin tree and the restore of the marketplace backup by their names.
        def fail_apply_and_restore(source, target, **directories):
            if (source, target) in (("plugin", "macroscope"), ("0", "marketplace.json")):
                raise OSError("simulated persistent filesystem failure")
            return original(source, target, **directories)

        with mock.patch.object(SYNC.os, "replace", side_effect=fail_apply_and_restore):
            with self.assertRaisesRegex(RuntimeError, "retained recovery files"):
                self.sync()
        owner = json.loads((self.output / ".macroscope-sync.lock/owner.json").read_text())
        self.assertEqual((Path(owner["transaction"]) / "backups/0").read_bytes(), original_market)
        recovery = json.loads((Path(owner["transaction"]) / "recovery.json").read_text())
        self.assertEqual(recovery[0]["target"], str(self.output.resolve() / ".claude-plugin/marketplace.json"))
        self.assertEqual(owner["sourceRef"], OPTIONS.ref)
        before = snapshot(self.output)
        with self.assertRaisesRegex(ValueError, "sync lock exists"):
            self.sync()
        self.assertEqual(before, snapshot(self.output))

    def test_existing_lock_rejects_concurrent_sync_without_changes(self):
        (self.output / ".macroscope-sync.lock").mkdir()
        before = snapshot(self.output)
        with self.assertRaisesRegex(ValueError, "sync lock exists"):
            self.sync()
        self.assertEqual(before, snapshot(self.output))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--back-repo", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--legacy-repo", default=str(SCRIPT.parent.parent))
    parser.add_argument("--legacy-ref")
    OPTIONS, remaining = parser.parse_known_args()
    print(f"Candidate: {OPTIONS.back_repo} @ {OPTIONS.ref}", flush=True)
    print(f"Legacy fixture: {OPTIONS.legacy_repo} @ {OPTIONS.legacy_ref or 'omitted'}", flush=True)
    unittest.main(argv=[str(SCRIPT), *remaining], verbosity=2)
