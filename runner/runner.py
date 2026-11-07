"""The runner of the benchmark machine: takes one job at a time from the run queue and runs it.

It holds `GET <queue>/runner/next` open until the queue has a job, so the machine accepts no
connections and nothing polls. Each job runs `job.sh` as another user, in a unit of its own, which
cannot read this process's token: the benchmarked code is a pull request's. Standard library only.

    python3 runner/runner.py      # configured by the environment, see `Config`
"""

import json, os, shlex, subprocess, sys, threading, time, urllib.error, urllib.request


class Config:
    def __init__(self, env=os.environ):
        self.queue = env.get("RUNNER_QUEUE", "https://benchmark.madsuite.org/queue")
        self.token = open(env["RUNNER_TOKEN_FILE"]).read().strip() if env.get("RUNNER_TOKEN_FILE") else ""
        self.live = env.get("RUNNER_LIVE", "/mnt/benchmark-live")
        # The command that runs a job as the job user and returns when it ends, given the unit name,
        # the live folder, the commit, the kind and the pull request. On the machine it is a root-owned
        # wrapper allowed by sudo, which prepares the folder and a fresh scratch and runs job.sh.
        self.start = shlex.split(env.get("RUNNER_START", "sudo -n /usr/local/sbin/benchjob-run"))
        self.stop = shlex.split(env.get("RUNNER_STOP", "sudo -n /usr/local/sbin/benchjob-stop"))
        self.preempt = shlex.split(env.get("RUNNER_PREEMPT", "sudo -n /usr/local/bin/ci-preempt"))


class Runner:
    def __init__(self, cfg, request=None):
        self.cfg = cfg
        self.request = request or self.http

    def http(self, method, path, body=None, timeout=90):
        req = urllib.request.Request(self.cfg.queue + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": "Bearer " + self.cfg.token, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read()
            return r.status, (json.loads(text) if text else None)

    def next(self):
        status, job = self.request("GET", "/runner/next")
        return job if status == 200 else None

    def watch_cancel(self, job, proc, cancelled):
        """Stop the job's unit when the queue says it was cancelled; return when the job ends."""
        while proc.poll() is None:
            try:
                _, answer = self.request("GET", f"/runner/cancel?id={job['id']}")
            except (urllib.error.URLError, OSError):
                time.sleep(30)
                continue
            if answer and answer.get("cancel") and proc.poll() is None:
                cancelled.set()
                subprocess.run([*self.cfg.stop, unit(job)])
                return

    def run(self, job):
        folder = job["folder"]
        if not (folder.startswith("pr-") and folder[3:].isdigit()) and not (folder.startswith("master-") and len(folder) == 15):
            raise ValueError(f"unexpected folder {folder!r}")
        if len(job["sha"]) != 40 or any(c not in "0123456789abcdef" for c in job["sha"]):
            raise ValueError(f"unexpected commit {job['sha']!r}")
        subprocess.run([*self.cfg.preempt, "start"])
        cancelled = threading.Event()
        try:
            proc = subprocess.Popen([*self.cfg.start, unit(job), os.path.join(self.cfg.live, folder), job["sha"], job["kind"], str(job.get("pr") or ""),
                                     "keep" if job.get("keep", True) else "fresh"])
            watcher = threading.Thread(target=self.watch_cancel, args=(job, proc, cancelled), daemon=True)
            watcher.start()
            rc = proc.wait()
        finally:
            subprocess.run([*self.cfg.preempt, "end"])
        state = "cancelled" if cancelled.is_set() else "finished" if rc == 0 else "failed"
        self.request("POST", "/runner/status", {"id": job["id"], "state": state})
        return state

    def serve(self):
        # Each request is held open by the queue until it has a job, so this loop is idle between
        # jobs. It waits a minute before asking again only when the queue cannot be reached.
        while True:
            try:
                job = self.next()
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    # a wrong or revoked token will not become right by retrying
                    sys.exit("the queue refused this runner's token")
                time.sleep(60)
                continue
            except (urllib.error.URLError, OSError):
                time.sleep(60)
                continue
            if job:
                print("job", job["id"], job["folder"], job["sha"], "->", self.run(job), flush=True)


def unit(job):
    return f"benchjob-{job['id']}"


if __name__ == "__main__":
    Runner(Config()).serve()
