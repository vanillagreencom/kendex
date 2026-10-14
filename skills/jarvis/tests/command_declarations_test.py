"""Surface: the shipped Jarvis declaration reaches the real install and check CLI."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
from desktop_world import World, kendex_path


class Declaration(World):
    def test_missing_agent_browser(self):
        kendex = kendex_path()
        if kendex is None:
            if os.environ.get("HARNESS_CI_REQUIRE_KENDEX"):
                self.fail("HARNESS_CI_REQUIRE_KENDEX requires the checkout's CLI")
            self.skipTest("kendex is unavailable on this host")
        project = self.root / "project"
        project.joinpath(".claude").mkdir(parents=True)
        source = Path(os.environ.get("JARVIS_TOOL_SKILL", Path(__file__).resolve().parents[1] / "SKILL.md"))
        declaration = source.read_text()
        catalog = project / "catalog/skills/jarvis"
        catalog.mkdir(parents=True)
        catalog.joinpath("SKILL.md").write_text(declaration)
        # These neutral siblings meet declaration dependencies. This fixture runs
        # no Jarvis script and does not exercise their runtime implementations.
        for sibling in ("mailbox", "orch"):
            path = project / "catalog/skills" / sibling
            path.mkdir()
            path.joinpath("SKILL.md").write_text('---\nname: '+sibling+'\ndescription: fixture sibling\n---\nFixture.\n')
        env = dict(self.env, KENDEX_REAL_HOME="1", KENDEX_BACKGROUND_REFRESH="off",
                   XDG_CONFIG_HOME=str(self.root / ".config"), XDG_CACHE_HOME=str(self.root / ".cache"),
                   XDG_DATA_HOME=str(self.root / ".local/share"))
        git = shutil.which("git")
        self.assertIsNotNone(git, "git is required to compare the occupied source")
        self.bin.joinpath("git").symlink_to(git)
        installed = subprocess.run([kendex, "add", str(project / "catalog"), "--skill", "jarvis",
                                    "--harness", "claude", "--method", "copy", "-y"],
                                   cwd=project, env=env, capture_output=True, timeout=30)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        # Only the fixture PATH is visible to dependency discovery.
        result = subprocess.run([kendex, "check", "--scope", "project", "--json", "--report-only"],
                                cwd=project, env=env, capture_output=True, timeout=30)
        report = json.loads(result.stdout)
        lines = [line for section in report["sections"] for line in section["lines"]]
        required = [line for line in lines if line["text"].startswith("kendex-command-missing: command=agent-browser ")]
        self.assertTrue(required, result.stdout)
        self.assertTrue(all(line["class"] == "drift" for line in required))
        self.assertEqual(result.returncode, 1, result.stderr)
        optional = [line for line in lines if line["text"].startswith("kendex-command-missing: command=op ")]
        self.assertTrue(optional, result.stdout)
        self.assertTrue(all(line["class"] == "notice" for line in optional))


if __name__ == "__main__":
    unittest.main()
