"""Tests of the runner and of job.sh, with the queue, sudo, git's remote and Julia replaced.

    python3 -m unittest discover -s runner
"""

import json, os, signal, stat, subprocess, sys, tempfile, textwrap, time, unittest

sys.path.insert(0, os.path.dirname(__file__))
import runner

HERE = os.path.dirname(os.path.abspath(__file__))


def script(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/bash\n" + textwrap.dedent(body))
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
    return path


class TestRunner(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.log = os.path.join(self.dir, "log")
        self.cfg = runner.Config({"RUNNER_LIVE": "/live",
                                  "RUNNER_START": script(os.path.join(self.dir, "start"), f'echo "start $@" >> {self.log}; sleep "${{SLEEP:-0}}"; exit "${{RC:-0}}"\n'),
                                  "RUNNER_STOP": script(os.path.join(self.dir, "stop"), f'echo "stop $@" >> {self.log}; pkill -f "{self.dir}/start" || true\n'),
                                  "RUNNER_PREEMPT": script(os.path.join(self.dir, "preempt"), f'echo "preempt $@" >> {self.log}\n')})
        self.sent, self.cancel = [], False

    def request(self, method, path, body=None):
        self.sent.append((method, path, body))
        if path.startswith("/runner/cancel"):
            time.sleep(0.2)
            return 200, {"cancel": self.cancel}
        return 204, None

    def job(self, **kw):
        return {"id": 3, "kind": "pr", "pr": 7, "sha": "a" * 40, "folder": "pr-7"} | kw

    def test_runs_a_job_between_preemptions(self):
        state = runner.Runner(self.cfg, self.request).run(self.job())
        self.assertEqual(state, "finished")
        lines = open(self.log).read().splitlines()
        self.assertEqual(lines[0], "preempt start")
        self.assertEqual(lines[1], f"start benchjob-3 /live/pr-7 {'a' * 40} pr 7 keep")
        self.assertEqual(lines[-1], "preempt end")
        self.assertEqual(self.sent[-1], ("POST", "/runner/status", {"id": 3, "state": "finished"}))

    def test_failure(self):
        os.environ["RC"] = "4"
        try:
            self.assertEqual(runner.Runner(self.cfg, self.request).run(self.job()), "failed")
        finally:
            del os.environ["RC"]

    def test_cancel(self):
        os.environ["SLEEP"] = "20"
        self.cancel = True
        try:
            t = time.time()
            self.assertEqual(runner.Runner(self.cfg, self.request).run(self.job()), "cancelled")
            self.assertLess(time.time() - t, 10)
        finally:
            del os.environ["SLEEP"]
        self.assertIn("stop benchjob-3", open(self.log).read())

    def test_refuses_what_the_queue_should_never_send(self):
        r = runner.Runner(self.cfg, self.request)
        for bad in (self.job(folder="../etc"), self.job(folder="pr-7/../x"), self.job(sha="a" * 39 + ";"), self.job(folder="master-abc")):
            with self.assertRaises(ValueError):
                r.run(bad)
        self.assertFalse(os.path.exists(self.log))   # nothing was started


class TestJob(unittest.TestCase):
    """job.sh against a local repository, with a Julia that writes a result file."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        src = os.path.join(self.dir, "src")
        subprocess.run(["git", "init", "-q", src], check=True)
        subprocess.run(["git", "-C", src, "-c", "user.name=x", "-c", "user.email=x@x", "commit", "-q", "--allow-empty", "-m", "c"], check=True)
        self.sha = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        bin = os.makedirs(os.path.join(self.dir, "bin")) or os.path.join(self.dir, "bin")
        script(os.path.join(bin, "julia"), """
            case "$*" in
              *setup.jl*) exit 0 ;;
              *run.jl*) root=${@: -1}; root=${root#--root=}; mkdir -p "$root/m"; echo case,status > "$root/m/acopf_default.csv"
                        sleep "${FAKE_RUN:-1}"; touch "$root/m/acopf_default.csv.complete" ;;
            esac
            """)
        self.env = dict(os.environ, PATH=bin + ":" + os.environ["PATH"], JOB_HOME=os.path.join(self.dir, "work"), JOB_SOURCE=src)
        self.live = os.path.join(self.dir, "live", "pr-7")

    def run_json(self):
        return json.load(open(os.path.join(self.live, "run.json")))

    def test_results_reach_the_live_folder(self):
        rc = subprocess.run([os.path.join(HERE, "job.sh"), self.live, self.sha, "pr", "7"], env=self.env, capture_output=True).returncode
        self.assertEqual(rc, 0)
        self.assertEqual(self.run_json(), {"repository": "madsuite-org/MadNLP.jl", "pr": "7", "commit": self.sha, "title": "", "state": "finished"})
        self.assertTrue(os.path.exists(os.path.join(self.live, "m", "acopf_default.csv")))
        self.assertIn(f"at {self.sha}", open(os.path.join(self.live, "job.log")).read())

    def test_keep_takes_over_and_fresh_throws_away(self):
        old = os.path.join(self.live, "m")
        os.makedirs(old)
        open(os.path.join(old, "cops_default.csv"), "w").write("old")
        subprocess.run([os.path.join(HERE, "job.sh"), self.live, self.sha, "pr", "7", "keep"], env=self.env, capture_output=True)
        self.assertTrue(os.path.exists(os.path.join(self.dir, "work", "results", "m", "cops_default.csv")))
        self.assertTrue(os.path.exists(os.path.join(old, "cops_default.csv")))
        subprocess.run(["rm", "-rf", os.path.join(self.dir, "work")])
        subprocess.run([os.path.join(HERE, "job.sh"), self.live, self.sha, "pr", "7", "fresh"], env=self.env, capture_output=True)
        self.assertFalse(os.path.exists(os.path.join(old, "cops_default.csv")))
        self.assertTrue(os.path.exists(os.path.join(old, "acopf_default.csv")))

    def test_alive_during_setup_and_options_reach_run(self):
        julia = os.path.join(self.dir, "bin", "julia")
        script(julia, """
            case "$*" in
              *setup.jl*) sleep 12 ;;
              *run.jl*) echo "$@" > "$JOB_HOME/args"; root=${@: -1}; root=${root#--root=}; mkdir -p "$root/m" ;;
            esac
            """)
        p = subprocess.Popen([os.path.join(HERE, "job.sh"), self.live, self.sha, "pr", "7", "keep", "augmented_mumps", "tol=1e-6,max_iter=5"],
                             env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(4)
        first = os.stat(os.path.join(self.live, "run.json")).st_mtime
        time.sleep(7)
        self.assertGreater(os.stat(os.path.join(self.live, "run.json")).st_mtime, first)   # refreshed during setup
        self.assertEqual(p.wait(timeout=30), 0)
        args = open(os.path.join(self.dir, "work", "args")).read()
        self.assertIn("--config=augmented_mumps --options=tol=1e-6,max_iter=5", args)
        self.assertNotEqual(subprocess.run([os.path.join(HERE, "job.sh"), self.live, self.sha, "pr", "7", "keep", "a;b"], env=self.env,
                                           capture_output=True).returncode, 0)

    def test_a_missing_commit_fails(self):
        rc = subprocess.run([os.path.join(HERE, "job.sh"), self.live, "b" * 40, "pr", "7"], env=self.env, capture_output=True).returncode
        self.assertNotEqual(rc, 0)
        self.assertEqual(self.run_json()["state"], "failed")
        self.assertIn("job: pr #7", open(os.path.join(self.live, "job.log")).read())

    def test_stopped_job_keeps_what_it_did(self):
        p = subprocess.Popen([os.path.join(HERE, "job.sh"), self.live, self.sha, "master", ""], env=dict(self.env, FAKE_RUN="30"),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 20
        while time.time() < deadline and not os.path.exists(os.path.join(self.live, "m", "acopf_default.csv")):
            time.sleep(0.2)
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=20)
        doc = self.run_json()
        self.assertEqual((doc["state"], doc["title"]), ("cancelled", "master " + self.sha[:8]))
        self.assertTrue(os.path.exists(os.path.join(self.live, "m", "acopf_default.csv")))


if __name__ == "__main__":
    unittest.main()
