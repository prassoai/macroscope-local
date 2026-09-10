#!/usr/bin/env python3
"""Installer regressions using owned homes, local downloads and child processes."""
import hashlib
import io
import itertools
import json
import os
from pathlib import Path
import platform
import signal
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
INSTALLER = Path(os.environ.get("TEST_INSTALLER", ROOT / "install.sh"))
BUNDLE = Path(os.environ.get("TEST_BUNDLE", ROOT))


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macroscope-adversarial-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.binary = self.root / "binary"
        self.binary.write_text('#!/bin/sh\nprintf "test-version\\n"\n')
        self.binary.chmod(0o755)
        self.env = {
            "HOME": str(self.home), "CODEX_HOME": str(self.home / ".codex"),
            "CLAUDE_CONFIG_DIR": str(self.home / ".claude"),
            "OPENCODE_CONFIG_DIR": str(self.home / ".config/opencode"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "TMPDIR": str(self.tmp), "SHELL": "/bin/bash",
            "PATH": str(self.bin) + ":/usr/bin:/bin",
            "FIXTURE_ROOT": str(self.root),
            "MACROSCOPE_TEST_NONINTERACTIVE": "1",
            "MACROSCOPE_LOCAL_BINARY_SOURCE": str(self.binary),
            "MACROSCOPE_PLUGIN_BUNDLE_SOURCE": str(BUNDLE),
            "MACROSCOPE_CODEX_APP_BINARY": str(self.root / "missing-codex"),
            "MACROSCOPE_CHATGPT_APP_BINARY": str(self.root / "missing-chatgpt"),
        }
        # pgrep and pkill are both violations now, not just pkill. The installer
        # identifies what to stop by the executable the kernel recorded, so any
        # command-line search is a regression to matching argv -- which silently
        # misses every PATH invocation and can match unrelated sessions.
        for name in ("rm", "pgrep", "pkill"):
            guard = self.bin / name
            guard.write_text('''#!/usr/bin/python3
import os, sys
name = os.path.basename(sys.argv[0])
root = os.path.realpath(os.environ["FIXTURE_ROOT"])
if name == "rm":
    for arg in sys.argv[1:]:
        if arg.startswith("-"): continue
        target = os.path.join(os.path.realpath(os.path.dirname(os.path.abspath(arg))), os.path.basename(arg))
        if os.path.commonpath([root, target]) != root:
            with open(os.path.join(root, "guard-violations"), "a") as f: f.write("removal escaped fixture\\n")
            print("BLOCKED test removal:", target, "outside", root, file=sys.stderr)
            raise SystemExit(97)
    os.execv("/bin/rm", ["rm", *sys.argv[1:]])
with open(os.path.join(root, "guard-violations"), "a") as f:
    f.write("installer matched processes by command line via %s\\n" % name)
raise SystemExit(97)
''')
            guard.chmod(0o755)
        if os.environ.get("TEST_BASELINE_SANDBOX") == "1":
            # The old macOS installer ignores TMPDIR with bare mktemp. Confine
            # its staging while reproducing other defects without touching it.
            helper = self.bin / "mktemp"
            helper.write_text('''#!/bin/sh
if [ "$*" = "-d" ]; then exec /usr/bin/mktemp -d "$TMPDIR/baseline.XXXXXX"; fi
exec /usr/bin/mktemp "$@"
''')
            helper.chmod(0o755)

    def tearDown(self):
        self.assertFalse((self.root / "guard-violations").exists(), "test concealed an installer fixture escape")

    def command(self, *args):
        return ["/bin/bash", str(INSTALLER), "--yes", "--no-path", "--no-wizard", *args]

    def install(self, *args, expected=0):
        result = subprocess.run(self.command(*args), env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertFalse((self.root / "guard-violations").exists(), "installer attempted host-wide fixture escape")
        return result.stdout + result.stderr

    def rejected(self, *args):
        # The guarantee is not the exit status: it is that a validation failure
        # applies nothing. An absent CLI proves only that one path was untouched,
        # so the whole home is compared instead.
        original = self.snapshot()
        result = subprocess.run(self.command(*args), env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "guard-violations").exists(), "rejection concealed host-wide fixture escape")
        self.assertEqual(original, self.snapshot(), "rejection applied changes before failing")
        return result.stdout + result.stderr

    def downloads(self):
        self.env.pop("MACROSCOPE_LOCAL_BINARY_SOURCE")
        self.env.pop("MACROSCOPE_PLUGIN_BUNDLE_SOURCE")
        self.archive = self.root / "bundle.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            archive.add(BUNDLE / ".claude-plugin", arcname=".claude-plugin")
            archive.add(BUNDLE / "plugins/macroscope", arcname="plugins/macroscope")
        arch = "arm64" if platform.machine() in ("arm64", "aarch64") else "amd64"
        self.asset = "macroscope-" + platform.system().lower() + "-" + arch
        self.metadata = {"tag_name": "test-version", "assets": [
            {"name": self.asset, "digest": "sha256:" + hashlib.sha256(self.binary.read_bytes()).hexdigest()},
            {"name": "macroscope-plugin-bundle.tar.gz", "digest": "sha256:" + hashlib.sha256(self.archive.read_bytes()).hexdigest()},
        ]}
        self.write_metadata()
        self.env["FIXTURE"] = str(self.root)
        curl = self.bin / "curl"
        curl.write_text('''#!/usr/bin/python3
import json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ["FIXTURE"])
url = next(a for a in sys.argv if a.startswith("https://"))
with (root / "urls.jsonl").open("a") as f: f.write(json.dumps(url) + "\\n")
dest = sys.argv[sys.argv.index("-o") + 1]
if "api.github.com" in url:
    source = root / "release.json"
elif "macroscope-plugin-bundle.tar.gz" in url:
    source = root / "bundle.tar.gz"
else:
    source = root / "binary"
if (root / "http-error").exists(): raise SystemExit(22)
shutil.copyfile(source, dest)
''')
        curl.chmod(0o755)

    def write_metadata(self):
        (self.root / "release.json").write_text(json.dumps(self.metadata))

    def test_invalid_metadata_is_never_missing_digest_grace(self):
        self.downloads()
        for content in ("{", "null", "[]", '{"tag_name":"test-version","assets":null}'):
            with self.subTest(content=content):
                (self.root / "release.json").write_text(content)
                self.assertIn("Invalid release metadata", self.rejected("--tools", "none"))

    def test_metadata_rejects_wrong_duplicate_and_invalid_assets(self):
        self.downloads()
        original = json.loads(json.dumps(self.metadata))
        for change in ("missing", "duplicate", "digest", "tag"):
            with self.subTest(change=change):
                self.metadata = json.loads(json.dumps(original))
                if change == "missing": self.metadata["assets"] = []
                if change == "duplicate": self.metadata["assets"].append(self.metadata["assets"][0])
                if change == "digest": self.metadata["assets"][0]["digest"] = "sha256:bad"
                if change == "tag": self.metadata["tag_name"] = "../escape"
                self.write_metadata()
                self.rejected("--tools", "none")

    def test_latest_is_resolved_once_before_any_asset_download(self):
        self.downloads()
        self.install("--tools", "all")
        urls = [json.loads(line) for line in (self.root / "urls.jsonl").read_text().splitlines()]
        self.assertEqual(sum("api.github.com" in url for url in urls), 1)
        self.assertTrue(urls[0].endswith("/releases/latest"))
        self.assertEqual(len(urls), 3)
        self.assertTrue(all("/releases/download/test-version/" in url for url in urls[1:]), urls)

    def test_explicit_version_must_match_metadata_and_binary(self):
        self.downloads()
        self.rejected("wrong-version", "--tools", "none")
        self.binary.write_text('#!/bin/sh\nprintf "wrong-binary-version\\n"\n')
        self.metadata["assets"][0]["digest"] = "sha256:" + hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.write_metadata()
        self.assertIn("version does not match", self.rejected("test-version", "--tools", "none"))

    def test_http_failure_leaves_existing_install_unchanged(self):
        self.install("--tools", "all")
        original = self.snapshot()
        self.downloads()
        (self.root / "http-error").touch()
        self.install("--mode", "update", "--tools", "all", expected=1)
        self.assertEqual(original, self.snapshot())

    def test_missing_digest_grace_is_explicit_and_strict_fails(self):
        self.downloads()
        for asset in self.metadata["assets"]: asset["digest"] = None
        self.write_metadata()
        self.env["MACROSCOPE_REQUIRE_CHECKSUM"] = "1"
        self.rejected("--tools", "all")
        self.env.pop("MACROSCOPE_REQUIRE_CHECKSUM")
        self.assertIn("WITHOUT integrity verification", self.install("--tools", "all"))

    def test_unsafe_and_truncated_archives_fail_before_apply(self):
        self.downloads()
        for kind in ("parent", "absolute", "symlink", "hardlink", "fifo", "duplicate", "truncated", "trailer", "crc"):
            with self.subTest(kind=kind):
                with tarfile.open(self.archive, "w:gz") as archive:
                    member = tarfile.TarInfo("ok")
                    if kind == "parent": member.name = "../escaped"
                    if kind == "absolute": member.name = str(self.root / "escaped")
                    if kind == "symlink": member.type, member.linkname = tarfile.SYMTYPE, str(self.root)
                    if kind == "hardlink": member.type, member.linkname = tarfile.LNKTYPE, str(self.binary)
                    if kind == "fifo": member.type = tarfile.FIFOTYPE
                    archive.addfile(member, io.BytesIO())
                    if kind == "duplicate": archive.addfile(member, io.BytesIO())
                if kind == "truncated": self.archive.write_bytes(self.archive.read_bytes()[:10])
                if kind == "trailer": self.archive.write_bytes(self.archive.read_bytes()[:-8])
                if kind == "crc":
                    content = bytearray(self.archive.read_bytes())
                    content[-8] ^= 1
                    self.archive.write_bytes(content)
                self.metadata["assets"][1]["digest"] = "sha256:" + hashlib.sha256(self.archive.read_bytes()).hexdigest()
                self.write_metadata()
                self.assertIn("unsafe plugin archive", self.rejected("--tools", "all"))
                self.assertFalse((self.root / "escaped").exists())

    def snapshot(self):
        result = {}
        for path in self.home.rglob("*"):
            if path.name in ("install.lock",): continue
            if path.is_symlink(): result[str(path.relative_to(self.home))] = ("link", os.readlink(path))
            elif path.is_file(): result[str(path.relative_to(self.home))] = (path.stat().st_mode, path.read_bytes())
        return result

    def test_archive_resource_limits_fail_before_apply(self):
        self.downloads()
        class Zeros:
            def read(self, size=-1):
                return b"0" * size
        for kind in ("file", "total", "members", "pax", "compressed", "negative-directory", "nonzero-directory"):
            with self.subTest(kind=kind):
                with tarfile.open(self.archive, "w:gz") as archive:
                    archive.add(BUNDLE / ".claude-plugin", arcname=".claude-plugin")
                    archive.add(BUNDLE / "plugins/macroscope", arcname="plugins/macroscope")
                    if kind in ("negative-directory", "nonzero-directory"):
                        directory = tarfile.TarInfo("sized-directory")
                        directory.type = tarfile.DIRTYPE
                        directory.size = -16 * 1024 * 1024 if kind == "negative-directory" else 1
                        archive.addfile(directory)
                    count = 5 if kind in ("total", "negative-directory") else 2049 if kind == "members" else 1
                    for number in range(count):
                        info = tarfile.TarInfo("padding-" + str(number))
                        info.size = 4 * 1024 * 1024 if kind in ("total", "negative-directory") else 5 * 1024 * 1024 if kind == "file" else 33 * 1024 * 1024 if kind == "pax" else 0
                        if kind == "pax": info.type = tarfile.XHDTYPE
                        archive.addfile(info, Zeros())
                if kind == "compressed":
                    with self.archive.open("r+b") as output: output.truncate(16 * 1024 * 1024 + 1)
                else:
                    self.assertLess(self.archive.stat().st_size, 128 * 1024, "high-expansion fixture must stay small")
                self.metadata["assets"][1]["digest"] = "sha256:" + hashlib.sha256(self.archive.read_bytes()).hexdigest()
                self.write_metadata()
                self.assertIn("plugin archive", self.rejected("--tools", "codex"))
                self.assertEqual(list(self.tmp.iterdir()), [])

    def test_foreign_opencode_skill_is_preserved_before_apply(self):
        target = self.home / ".config/opencode/skills/codereview/SKILL.md"
        target.parent.mkdir(parents=True)
        target.write_text("User-owned review workflow\n")
        original = self.snapshot()
        self.assertIn("not Macroscope-owned", self.rejected("--tools", "all"))
        self.assertEqual(original, self.snapshot())

    def test_all_sixteen_host_selections_install_only_requested_files(self):
        original_home = self.home
        for mask in itertools.product((False, True), repeat=4):
            names = [name for name, enabled in zip(("claude", "codex", "cursor", "opencode"), mask) if enabled]
            with self.subTest(tools=names):
                self.home = original_home / ("-".join(names) or "none")
                self.home.mkdir()
                env_before = self.env.copy()
                self.env = {key: value.replace(str(original_home), str(self.home)) for key, value in self.env.items()}
                self.install("--tools", ",".join(names) or "none")
                paths = (".claude/settings.json", "plugins/macroscope/.codex-plugin/plugin.json",
                         ".cursor/plugins/local/macroscope/.cursor-plugin/plugin.json", ".config/opencode/plugins/macroscope.js")
                for expected, relative in zip(mask, paths):
                    self.assertEqual((self.home / relative).exists(), expected, relative)
                self.env = env_before
        self.home = original_home

    def test_invalid_and_mismatched_plugin_manifests_fail_before_apply(self):
        source = self.root / "local-bundle"
        shutil.copytree(BUNDLE / "plugins", source / "plugins")
        shutil.copytree(BUNDLE / ".claude-plugin", source / ".claude-plugin")
        self.env["MACROSCOPE_PLUGIN_BUNDLE_SOURCE"] = str(source)
        manifest = source / "plugins/macroscope/.codex-plugin/plugin.json"
        original = manifest.read_text()
        for version in ("../../escape", "different-version", None):
            with self.subTest(version=version):
                data = json.loads(original)
                data["version"] = version
                manifest.write_text(json.dumps(data))
                self.rejected("--tools", "all")

    def test_missing_hash_tool_fails_closed(self):
        self.downloads()
        script = '''source "$1"
TMP_DIR="$2/unit-stage"
mkdir -p "$TMP_DIR"
INSTALL_VERSION=test-version
sha256_of() { return 2; }
verify_downloaded_artifact "$2/binary" "$3" "fixture binary"
'''
        env = {**self.env, "MACROSCOPE_SOURCE_ONLY": "1"}
        result = subprocess.run(["/bin/bash", "-c", script, "test", str(INSTALLER), str(self.root), self.asset], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No SHA-256 tool", result.stdout)
        self.assertFalse((self.home / ".local/bin/macroscope").exists())

    def test_partial_binary_copy_failure_preserves_files_and_cleans_temp(self):
        self.install("--tools", "all")
        original = self.snapshot()
        cp = self.bin / "cp"
        cp.write_text('''#!/usr/bin/python3
import os, pathlib, sys
if ".macroscope.new." in sys.argv[-1]:
    pathlib.Path(sys.argv[-1]).write_bytes(b"partial disk-full fixture")
    raise SystemExit(1)
os.execv("/bin/cp", ["cp", *sys.argv[1:]])
''')
        cp.chmod(0o755)
        self.install("--mode", "update", "--tools", "all", expected=1)
        self.assertEqual(original, self.snapshot())
        # "cleans temp" is half the promise: a preserved home over an abandoned
        # staging tree still fills the disk one failed update at a time.
        self.assertEqual(list(self.tmp.iterdir()), [])

    def metadata_snapshot(self):
        result = {}
        for path in [self.home, *self.home.rglob("*")]:
            info = path.lstat()
            row = {"mode": info.st_mode, "size": info.st_size, "mtime_ns": info.st_mtime_ns}
            if path.is_symlink(): row["link"] = os.readlink(path)
            elif path.is_file(): row["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            result[str(path.relative_to(self.home))] = row
        return result

    def test_repair_dry_run_preserves_install_state_and_owned_process(self):
        """A dry run reports what a repair would do and must do none of it. The
        installed binary is replaced with a real copy of /bin/sleep so the
        running child is genuinely one of the processes a live repair stops:
        the child holds the default SIGTERM disposition, so its survival is
        proof that no signal was sent, not merely that none was fatal."""
        self.install("--tools", "all")
        executable = self.home / ".local/bin/macroscope"
        executable.unlink()
        shutil.copy("/bin/sleep", executable)
        child = subprocess.Popen([str(executable), "30"], env=self.env)
        try:
            self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
            for output_format in ("text", "json"):
                with self.subTest(format=output_format):
                    before = self.metadata_snapshot()
                    result = subprocess.run(self.command("--dry-run", "--format", output_format), env=self.env, capture_output=True, text=True, timeout=15)
                    after = self.metadata_snapshot()
                    changed = sorted(key for key in set(before) | set(after) if before.get(key) != after.get(key))
                    print(json.dumps({"repairDryRunFormat": output_format, "changedPaths": changed, "ownedProcessExit": child.poll(), "exitCode": result.returncode}), flush=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(before, after, "repair dry-run changed files, metadata, state, or lock")
                    self.assertIsNone(child.poll(), "repair dry-run signalled its installed process")
                    if output_format == "json":
                        self.assertEqual(json.loads(result.stdout), {"success": True, "dryRun": True, "mode": "repair", "tools": ""})
                    else:
                        self.assertIn("Repair dry run", result.stdout)
        finally:
            if child.poll() is None: child.terminate()
            child.wait(timeout=5)

    def test_repair_dry_run_does_not_create_state_or_lock(self):
        self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
        for output_format in ("text", "json"):
            with self.subTest(format=output_format):
                before = self.metadata_snapshot()
                self.install("--dry-run", "--format", output_format)
                self.assertEqual(before, self.metadata_snapshot())
                self.assertEqual(list(self.home.iterdir()), [])

    def test_repair_preserves_unrelated_named_process(self):
        """Sharing a basename with an installed binary is not grounds for being
        killed. A real binary at an unowned path is the case that matters: it
        would match any search by name, and its executable identity is the only
        thing that distinguishes it from the file repair actually owns."""
        foreign = self.root / "foreign/macroscope"
        foreign.parent.mkdir()
        shutil.copy("/bin/sleep", foreign)
        child = subprocess.Popen([str(foreign), "30"], env=self.env)
        try:
            self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
            self.install("--tools", "none")
            self.assertIsNone(child.poll())
            self.assertTrue(foreign.exists())
        finally:
            if child.poll() is None: child.terminate()
            child.wait(timeout=5)

    def test_repair_stops_a_binary_launched_through_path(self):
        """The ordinary way to run an installed CLI is by name, which leaves
        argv[0] as the bare name and the absolute path nowhere in the command
        line. Searching the command line for the installation path therefore
        finds nothing and repair rewrites the binary under a live process --
        exactly the corruption stopping processes first exists to prevent. The
        process is identified by the executable the kernel recorded at exec."""
        executable = self.home / ".local/bin/macroscope"
        executable.parent.mkdir(parents=True)
        shutil.copy("/bin/sleep", executable)
        child = subprocess.Popen(["macroscope", "30"], executable=str(executable), env=self.env)
        try:
            self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
            self.install("--tools", "none")
            self.assertEqual(child.wait(timeout=5), -signal.SIGTERM,
                             "repair left a PATH-invoked process running from the binary it rewrites")
        finally:
            if child.poll() is None: child.kill()
            child.wait(timeout=5)

    def test_repair_stops_go_bin_processes_and_escalates_past_a_term_refusal(self):
        """cleanup_binaries rewrites $HOME/go/bin as well as $HOME/.local/bin, so
        repair must stop processes running from either path first: replacing a
        binary under a live process is the corruption this prevents. A process
        that ignores SIGTERM must still be gone before cleanup, so termination
        waits and escalates to SIGKILL on the same executable identity."""
        stubborn = self.home / "go/bin/macroscope-mcp"
        stubborn.parent.mkdir(parents=True)
        shutil.copy("/bin/sh", stubborn)
        child = subprocess.Popen([str(stubborn), "-c", 'trap "" TERM; while :; do sleep 1; done'], env=self.env)
        try:
            self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
            self.install("--tools", "none")
            self.assertEqual(child.wait(timeout=5), -signal.SIGKILL, "TERM-ignoring go/bin process outlived repair")
            self.assertFalse(stubborn.exists() or stubborn.is_symlink(), "repair left the go/bin binary it rewrites")
        finally:
            if child.poll() is None: child.kill()
            child.wait(timeout=5)

    def test_install_lock_relinked_after_validation_is_refused_without_truncating_it(self):
        """acquire_install_lock validates the lock pathname and then opens it, and
        the validation is stale the moment it returns. So the open must destroy
        nothing -- `exec 9>` is O_TRUNC and would empty whatever it lands on --
        and the descriptor must be proved to be the file the pathname still
        names before the lock is taken. A hard link planted in that window is
        the reachable case: it is not a symlink, so every pathname check passes,
        and it aims the installer at a file with another name and other
        contents."""
        precious = self.root / "precious.toml"
        precious.write_text("user configuration\n")
        shim = self.bin / "mkdir"
        shim.write_text(f'''#!/usr/bin/python3
import os, subprocess, sys
subprocess.run(["/bin/mkdir", *sys.argv[1:]], check=True)
lock = os.path.join(os.environ["HOME"], ".local/state/macroscope/install.lock")
if os.path.isdir(os.path.dirname(lock)) and not os.path.lexists(lock):
    os.link({str(precious)!r}, lock)
''')
        shim.chmod(0o755)
        result = subprocess.run(self.command("--tools", "none"), env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Installer lock", result.stdout + result.stderr)
        self.assertEqual(precious.read_text(), "user configuration\n",
                         "the installer truncated the file its lock was hard-linked to")

    def test_repair_refuses_to_replace_a_foreign_codex_registration(self):
        """A repair selects no tools, so gating the foreign-source refusal on the
        selected tool list disarmed it on the one path that most needs it:
        repair is what goes on to delete $HOME/plugins/macroscope. A
        registration whose source is not one we write is somebody else's
        plugin, and repair must refuse rather than remove it."""
        marketplace = self.home / ".agents/plugins/marketplace.json"
        marketplace.parent.mkdir(parents=True)
        marketplace.write_text(json.dumps({"name": "local-user-plugins", "plugins": [
            {"name": "macroscope", "source": {"source": "git", "path": "https://example.invalid/other.git"}}]}))
        foreign = self.home / "plugins/macroscope"
        foreign.mkdir(parents=True)
        (foreign / "plugin.json").write_text('{"name": "macroscope"}\n')
        self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
        result = subprocess.run(self.command("--tools", "none"), env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("foreign source", result.stdout + result.stderr)
        self.assertTrue((foreign / "plugin.json").exists(), "repair deleted a foreign Codex plugin")

    def test_recovery_marker_symlink_planted_after_the_lock_check_is_not_followed(self):
        """acquire_install_lock inspects the recovery marker before staging and
        downloading, so its verdict is stale by the time the marker is written.
        A symlink planted in that window must not be followed: the installer
        refuses, and the file it aimed at keeps its contents."""
        outside = self.root / "precious.toml"
        outside.write_text("user configuration\n")
        cp = self.bin / "cp"
        cp.write_text('''#!/usr/bin/python3
import os, sys
marker = os.path.join(os.environ["HOME"], ".local/state/macroscope/install-recovery")
if os.path.isdir(os.path.dirname(marker)) and not os.path.lexists(marker):
    os.symlink(os.path.join(os.environ["FIXTURE_ROOT"], "precious.toml"), marker)
os.execv("/bin/cp", ["cp", *sys.argv[1:]])
''')
        cp.chmod(0o755)
        self.assertIn("recovery marker", self.install("--tools", "all", expected=1))
        self.assertEqual(outside.read_text(), "user configuration\n")
        self.assertFalse((self.home / ".local/bin/macroscope").exists())

    def test_null_registry_containers_do_not_abort_the_installer(self):
        """Registry files another tool wrote can carry a null plugin container.
        A present key holding null is not a missing key, so `.get(k, default)`
        and `setdefault` both hand back the null and the next iteration raises.
        Nothing foreign is registered in a null container: there is nothing to
        preserve and no reason to refuse. This is reached whenever the host is
        selected, so it is the install and update path, not repair, where
        SELECTED_TOOLS is empty and the ownership loop never executes."""
        marketplace = self.home / ".agents/plugins/marketplace.json"
        installed = self.home / ".claude/plugins/installed_plugins.json"
        for path in (marketplace, installed):
            path.parent.mkdir(parents=True)
            path.write_text('{"plugins": null}')
        self.install("--tools", "claude,codex")
        self.assertEqual([entry["name"] for entry in json.loads(marketplace.read_text())["plugins"]], ["macroscope"])
        self.assertIn("macroscope@macroscope-local", json.loads(installed.read_text())["plugins"])

    def test_symlinked_opencode_skill_is_rejected_without_target_mutation(self):
        foreign = self.root / "foreign"
        foreign.mkdir()
        (foreign / "SKILL.md").write_text("macroscope codereview; user customization")
        target = self.home / ".config/opencode/skills/codereview"
        target.parent.mkdir(parents=True)
        target.symlink_to(foreign, target_is_directory=True)
        self.rejected("--tools", "all")
        self.assertTrue(target.is_symlink())
        self.assertEqual((foreign / "SKILL.md").read_text(), "macroscope codereview; user customization")

    def test_deselecting_codex_refuses_to_delete_a_foreign_registration(self):
        """Deselecting Codex on an update is a removal path: it `rm -rf`s
        $HOME/plugins/macroscope. If the registration names a foreign source,
        that directory is somebody else's, and deleting it is the same
        destruction the repair path refuses -- so the run aborts before
        touching anything, leaving the registration, the plugin directory and
        a symlinked config exactly as they were. Deselection selects Codex in
        no list, which is why gating this on the selected tools disarms it."""
        self.install("--tools", "codex")
        marketplace = self.home / ".agents/plugins/marketplace.json"
        data = json.loads(marketplace.read_text())
        data["plugins"][0]["source"] = {"source": "github", "repo": "example/foreign"}
        marketplace.write_text(json.dumps(data))
        plugin = self.home / "plugins/macroscope"
        self.assertTrue(plugin.is_dir())
        config = self.home / ".codex/config.toml"
        original_config = config.read_bytes()
        target = self.home / "managed.toml"
        config.rename(target)
        config.symlink_to(target)
        self.assertIn("foreign source", self.install("--mode", "update", "--tools", "none", expected=1))
        self.assertEqual(json.loads(marketplace.read_text())["plugins"], data["plugins"])
        self.assertTrue(plugin.is_dir(), "a deselecting update deleted a foreign source's plugin directory")
        self.assertTrue(config.is_symlink())
        self.assertEqual(target.read_bytes(), original_config)

    def test_owned_codex_symlink_cleanup_and_foreign_cache_preservation(self):
        self.install("--tools", "codex")
        other = self.home / ".codex/plugins/cache/foreign-market/macroscope/local/keep"
        other.parent.mkdir(parents=True)
        other.write_text("foreign")
        config = self.home / ".codex/config.toml"
        target = self.home / "managed.toml"
        config.rename(target)
        config.symlink_to(target)
        self.install("--mode", "update", "--tools", "none")
        self.assertTrue(config.is_symlink())
        self.assertNotIn('[plugins."macroscope@local-user-plugins"]', target.read_text())
        self.assertEqual(other.read_text(), "foreign")

    def test_rollback_preserves_every_marketplace_cache(self):
        self.install("--tools", "codex")
        other = self.home / ".codex/plugins/cache/foreign-market/macroscope/local/keep"
        other.parent.mkdir(parents=True)
        other.write_text("foreign")
        original = self.snapshot()
        self.env["MACROSCOPE_TEST_FAIL_AFTER_LEGACY_CLEANUP"] = "1"
        self.install("--mode", "update", "--tools", "none", expected=71)
        self.assertEqual(original, self.snapshot())

    def copy_barrier(self, rollback_failure=False):
        self.env["BARRIER"] = str(self.root)
        cp = self.bin / "cp"
        cp.write_text('''#!/usr/bin/python3
import os, pathlib, sys, time
root = pathlib.Path(os.environ["BARRIER"])
if ".macroscope.new." in sys.argv[-1]:
    (root / "ready").touch()
    deadline = time.monotonic() + 10
    while not (root / "release").exists():
        if time.monotonic() > deadline: raise SystemExit(98)
        time.sleep(.02)
if (root / "fail-restore").exists() and ".macroscope-restore." in sys.argv[-1]: raise SystemExit(1)
os.execv("/bin/cp", ["cp", *sys.argv[1:]])
''')
        cp.chmod(0o755)
        if rollback_failure: (self.root / "fail-restore").touch()

    def start_blocked(self):
        child = subprocess.Popen(self.command("--tools", "none"), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        deadline = time.monotonic() + 15
        while not (self.root / "ready").exists():
            if child.poll() is not None: self.fail(child.communicate()[0])
            if time.monotonic() > deadline:
                child.terminate()
                self.fail(child.communicate(timeout=15)[0])
            time.sleep(.02)
        return child

    def test_concurrent_installer_cannot_overwrite_active_transaction(self):
        self.copy_barrier()
        child = self.start_blocked()
        try:
            self.assertIn("Another Macroscope installer", self.install("--tools", "none", expected=75))
        finally:
            (self.root / "release").touch()
            output = child.communicate(timeout=20)[0]
        self.assertEqual(child.returncode, 0, output)
        self.assertEqual((self.home / ".local/bin/macroscope").read_bytes(), self.binary.read_bytes())

    def test_repair_and_alternate_xdg_state_cannot_bypass_active_lock(self):
        self.copy_barrier()
        child = self.start_blocked()
        try:
            self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
            self.assertIn("Another Macroscope installer", self.install("--tools", "none", expected=75))
            self.env.pop("MACROSCOPE_REPAIR_ONLY")
            self.env["XDG_STATE_HOME"] = str(self.home / "alternate-state")
            self.assertIn("Another Macroscope installer", self.install("--tools", "none", expected=75))
        finally:
            (self.root / "release").touch()
            output = child.communicate(timeout=20)[0]
        self.assertEqual(child.returncode, 0, output)

    def test_repair_cannot_destroy_pending_recovery(self):
        """Backups a killed installer left behind outrank anything a later run
        wants to do, repair included: repair rewrites the very binaries those
        backups hold. The refusal must also name the way out, because the user
        cannot guess which file to remove."""
        self.install("--tools", "all")
        recovery = self.root / "owned-recovery"
        recovery.mkdir()
        marker = self.home / ".local/state/macroscope/install-recovery"
        marker.write_text(str(recovery) + "\n")
        original = self.snapshot()
        self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
        output = self.install("--tools", "none", expected=1)
        self.assertIn("previous installation was interrupted", output)
        self.assertIn(f"rm -f '{marker}'", output, "the refusal did not name the command that clears it")
        self.assertEqual(original, self.snapshot())

    def test_stale_recovery_marker_with_reaped_backups_does_not_wedge_the_installer(self):
        """The marker records backups under $TMPDIR, which the OS reaps, and the
        CLI kills this script with SIGKILL at its own two-minute update timeout
        -- so an ordinary slow download on an ordinary machine leaves a marker
        pointing at nothing. Refusing on it would wedge update, fresh install
        and repair together, with repair being the documented recovery path and
        no other code path removing the marker. A marker whose backups are gone
        protects nothing, so it is reported and cleared rather than obeyed."""
        self.install("--tools", "all")
        marker = self.home / ".local/state/macroscope/install-recovery"
        marker.write_text(str(self.root / "reaped-by-the-os") + "\n")
        for mode in ({}, {"MACROSCOPE_REPAIR_ONLY": "1"}):
            with self.subTest(repair=bool(mode)):
                marker.write_text(str(self.root / "reaped-by-the-os") + "\n")
                self.env.update(mode)
                self.assertIn("stale recovery marker", self.install("--tools", "none"))
                self.assertFalse(marker.exists(), "the stale marker survived the run that ignored it")
                self.env.pop("MACROSCOPE_REPAIR_ONLY", None)

    def test_unrelated_malformed_codex_configuration_does_not_block_cli(self):
        marketplace = self.home / ".agents/plugins/marketplace.json"
        marketplace.parent.mkdir(parents=True)
        marketplace.write_text("{not-json")
        self.install("--tools", "none")
        self.assertEqual(marketplace.read_text(), "{not-json")

    def test_opencode_deselection_and_repair_preserve_foreign_replacements(self):
        self.install("--tools", "opencode")
        skill = self.home / ".config/opencode/skills/codereview/SKILL.md"
        skill.write_text("Foreign workflow invoking macroscope codereview --raw\n")
        self.install("--mode", "update", "--tools", "none")
        self.assertEqual(skill.read_text(), "Foreign workflow invoking macroscope codereview --raw\n")
        self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
        self.install("--tools", "none")
        self.assertEqual(skill.read_text(), "Foreign workflow invoking macroscope codereview --raw\n")

    def test_repair_rejects_unsafe_marketplace_and_snapshot_never_traverses(self):
        marketplace = self.home / ".agents/plugins/marketplace.json"
        marketplace.parent.mkdir(parents=True)
        marketplace.write_text(json.dumps({"name": "../../../../outside", "plugins": [
            {"name": "macroscope", "source": {"source": "local", "path": "./plugins/macroscope"}}
        ]}))
        sentinel = self.root / "outside/macroscope/keep"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text("preserve")
        self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
        self.assertIn("Invalid Codex marketplace name", self.rejected("--tools", "none"))
        self.env.pop("MACROSCOPE_REPAIR_ONLY")
        self.env["MACROSCOPE_TEST_FAIL_AFTER_BINARY"] = "1"
        self.install("--tools", "none", expected=70)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertIn("../../../../outside", marketplace.read_text())

    def test_legacy_unmarked_opencode_upgrade_is_supported(self):
        legacy = Path(os.environ.get("TEST_LEGACY_BUNDLE", BUNDLE))
        if not json.loads((legacy / "plugins/macroscope/.claude-plugin/plugin.json").read_text())["version"].startswith("1."):
            self.fail("legacy OpenCode upgrade requires a pinned 1.x TEST_LEGACY_BUNDLE fixture")
        self.env["MACROSCOPE_PLUGIN_BUNDLE_SOURCE"] = str(legacy)
        self.install("--tools", "opencode")
        root = self.home / ".config/opencode"
        marker = "Installed by Macroscope installer; managed OpenCode integration."
        for target in root.rglob("*"):
            if target.is_file():
                target.write_text("\n".join(line for line in target.read_text().split("\n") if marker not in line).rstrip("\n") + "\n")
        # Restore exact historical bytes, including original trailing newlines.
        for relative, source in [("plugins/macroscope.js", "opencode/macroscope.js"),
                                 ("commands/macroscope-codereview.md", "commands/macroscope-codereview.md"),
                                 ("commands/macroscope-autoloop.md", "commands/macroscope-autoloop.md"),
                                 ("skills/codereview/SKILL.md", "skills/codereview/SKILL.md"),
                                 ("skills/autoloop/SKILL.md", "skills/autoloop/SKILL.md")]:
            shutil.copyfile(legacy / "plugins/macroscope" / source, root / relative)
        self.env["MACROSCOPE_PLUGIN_BUNDLE_SOURCE"] = str(BUNDLE)
        self.install("--mode", "update", "--tools", "opencode")
        self.assertIn(marker, (root / "skills/codereview/SKILL.md").read_text())

    def test_opencode_preserves_custom_cli_wrapper_and_added_resources(self):
        skill = self.home / ".config/opencode/skills/codereview/SKILL.md"
        skill.parent.mkdir(parents=True)
        content = "My review workflow uses macroscope codereview --raw and custom checks.\n"
        skill.write_text(content)
        self.assertIn("not Macroscope-owned", self.rejected("--tools", "opencode"))
        self.assertEqual(skill.read_text(), content)
        skill.unlink()
        skill.parent.rmdir()
        self.install("--tools", "opencode")
        resource = skill.parent / "personal-checks.md"
        resource.write_text("private custom checks")
        self.install("--mode", "update", "--tools", "none")
        self.assertEqual(resource.read_text(), "private custom checks")
        self.env["MACROSCOPE_REPAIR_ONLY"] = "1"
        self.install("--tools", "none")
        self.assertEqual(resource.read_text(), "private custom checks")

    def test_state_parent_symlink_and_invalid_lock_types_fail_before_apply(self):
        state_parent = self.home / ".local/state"
        state_parent.parent.mkdir(parents=True)
        foreign = self.root / "foreign-state"
        foreign.mkdir()
        state_parent.symlink_to(foreign, target_is_directory=True)
        self.rejected("--tools", "none")
        self.assertEqual(list(foreign.iterdir()), [])
        state_parent.unlink()
        state_parent.mkdir()
        lock = state_parent / "macroscope/install.lock"
        lock.parent.mkdir()
        for kind in ("symlink", "fifo", "directory", "hardlink"):
            with self.subTest(kind=kind):
                if kind == "symlink": lock.symlink_to(foreign / "lock")
                elif kind == "fifo": os.mkfifo(lock)
                elif kind == "directory": lock.mkdir()
                else:
                    source = foreign / "hardlink"
                    source.write_text("keep")
                    os.link(source, lock)
                self.rejected("--tools", "none")
                if kind == "directory": lock.rmdir()
                else: lock.unlink()

    def test_candidate_missing_overlays_fail_but_legacy_bundle_remains_supported(self):
        source = self.root / "overlay-bundle"
        shutil.copytree(BUNDLE / "plugins", source / "plugins")
        shutil.copytree(BUNDLE / ".claude-plugin", source / ".claude-plugin")
        self.env["MACROSCOPE_PLUGIN_BUNDLE_SOURCE"] = str(source)
        shutil.rmtree(source / "plugins/macroscope/host-overlays")
        for host in ("claude", "codex", "cursor"):
            manifest = source / ("plugins/macroscope/." + host + "-plugin/plugin.json")
            data = json.loads(manifest.read_text())
            data["version"] = "2.0.0"
            manifest.write_text(json.dumps(data))
        market = source / ".claude-plugin/marketplace.json"
        data = json.loads(market.read_text())
        data["plugins"][0]["version"] = "2.0.0"
        market.write_text(json.dumps(data))
        self.rejected("--tools", "claude,codex")
        for host in ("claude", "codex", "cursor"):
            manifest = source / ("plugins/macroscope/." + host + "-plugin/plugin.json")
            data = json.loads(manifest.read_text())
            data["version"] = "1.5.1"
            manifest.write_text(json.dumps(data))
        data = json.loads(market.read_text())
        data["plugins"][0]["version"] = "1.5.1"
        market.write_text(json.dumps(data))
        self.install("--tools", "claude,codex")

    def test_term_during_apply_rolls_back_then_allows_retry(self):
        self.install("--tools", "none")
        original = self.snapshot()
        self.copy_barrier()
        child = self.start_blocked()
        child.send_signal(signal.SIGTERM)
        (self.root / "release").touch()
        output = child.communicate(timeout=20)[0]
        self.assertEqual(child.returncode, 143, output)
        self.assertEqual(original, self.snapshot())
        self.install("--tools", "none")

    def test_kill_preserves_recovery_and_blocks_unreviewed_retry(self):
        self.copy_barrier()
        child = self.start_blocked()
        child.kill()  # Only the Popen child owned by this test.
        (self.root / "release").touch()
        child.communicate(timeout=20)
        marker = self.home / ".local/state/macroscope/install-recovery"
        self.assertTrue(marker.is_file())
        self.assertTrue((Path(marker.read_text().strip()) / "rollback.log").is_file())
        output = self.install("--tools", "none", expected=1)
        self.assertIn("previous installation was interrupted", output)

    def test_failed_rollback_keeps_original_backups_and_recovery_marker(self):
        self.install("--tools", "none")
        original = (self.home / ".local/bin/macroscope").read_bytes()
        self.copy_barrier(rollback_failure=True)
        (self.root / "release").touch()
        self.env["MACROSCOPE_TEST_FAIL_AFTER_BINARY"] = "1"
        output = self.install("--tools", "none", expected=70)
        self.assertIn("Rollback is incomplete", output)
        marker = self.home / ".local/state/macroscope/install-recovery"
        recovery = Path(marker.read_text().strip())
        self.assertEqual((recovery / "rollback/1").read_bytes(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
