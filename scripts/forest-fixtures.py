#!/usr/bin/env python3
"""Synthetic repositories for the forest spike (docs/forest/PLAN.md).

Usage: scripts/forest-fixtures.py <destination> [count=64] [seed=7]

Writes <count> repositories under <destination>/<group>/<name>, grouped into folders of uneven size
(so a folder pin finds them two levels down), each with its own history: a trunk of 4-600 commits
whose last commit is anywhere from an hour to a year old, and 0-16 branches (some with
sub-branches, some merged and left as buds, some older than the 120-day window), a few checked out
in linked worktrees under <destination>/_worktrees. Histories are built with `git fast-import`, so
64 repositories take a few seconds. Local only: no network, nothing outside <destination>.
"""
import os
import random
import subprocess
import sys
import time

TREES = """alder ash aspen balsa baobab beech birch boxwood buckeye cedar cherry chestnut cypress dogwood elder elm
fig fir ginkgo hawthorn hazel hemlock hickory holly hornbeam ironwood juniper larch laurel linden locust magnolia
mahogany maple mulberry oak olive pawpaw pear pecan pine plane poplar quince redwood rowan sequoia spruce sumac
sycamore tamarack teak walnut willow yew yucca zelkova catalpa banyan mangrove acacia""".split()

GROUPS = ["apps", "tools", "games", "web", "labs", "notes", "clients", "archive"]
WEIGHTS = [14, 12, 10, 8, 7, 6, 4, 3]

PREFIXES = ["feature", "fix", "chore", "spike", "refactor", "docs", "release", "hotfix", "exp", "wip"]
TOPICS = """login cart search upload sync cache theme layout parser router queue export import billing
onboarding settings telemetry retry pagination sidebar toolbar shortcuts undo draft preview offline
migrate cleanup lint typing perf a11y i18n dark-mode emoji avatars webhooks scheduler importer""".split()

DAY = 86400


def trunk_count(rng):
    r = rng.random()
    if r < 0.30:
        return rng.randint(4, 20)
    if r < 0.65:
        return rng.randint(21, 80)
    if r < 0.90:
        return rng.randint(81, 250)
    return rng.randint(251, 600)


def last_age_days(rng):
    r = rng.random()
    if r < 0.25:
        return rng.uniform(0.05, 2)
    if r < 0.50:
        return rng.uniform(2, 14)
    if r < 0.75:
        return rng.uniform(14, 90)
    return rng.uniform(90, 400)


def branch_count(rng):
    r = rng.random()
    if r < 0.15:
        return 0
    if r < 0.60:
        return rng.randint(1, 4)
    if r < 0.88:
        return rng.randint(5, 9)
    return rng.randint(10, 16)


def make_repo(path, seed, now):
    rng = random.Random(seed)
    os.makedirs(path, exist_ok=True)
    subprocess.run(["git", "init", "-q", "-b", "main", path], check=True)
    n = trunk_count(rng)
    newest = now - last_age_days(rng) * DAY
    span = max(n, 8) * rng.uniform(0.4, 3.0) * DAY
    # Trunk commit i (0 = oldest); gaps vary, so activity comes in bursts.
    gaps = [rng.expovariate(1.0) ** 1.4 + 0.05 for _ in range(n - 1)]
    total = sum(gaps) or 1
    times = [newest]
    for g in reversed(gaps):
        times.append(times[-1] - span * g / total)
    times.reverse()  # oldest first
    out = []
    mark = [0]

    def commit(ref, when, msg, parent=None, merge=None, first=False):
        mark[0] += 1
        m = mark[0]
        out.append(f"commit {ref}\nmark :{m}\ncommitter T <t@example.com> {int(when)} +0000\n"
                   f"data {len(msg)}\n{msg}\n")
        if parent:
            out.append(f"from :{parent}\n")
        if merge:
            out.append(f"merge :{merge}\n")
        if first:
            out.append("M 100644 inline README\ndata 6\nhello\n")
        out.append("\n")
        return m

    trunk = []
    for i, t in enumerate(times):
        trunk.append(commit("refs/heads/main", t, f"trunk {i}", parent=trunk[-1] if trunk else None, first=i == 0))

    names = set()

    def branch_name():
        for _ in range(50):
            name = f"{rng.choice(PREFIXES)}/{rng.choice(TOPICS)}"
            if rng.random() < 0.4:
                name += f"-{rng.randint(2, 99)}"
            if name not in names:
                names.add(name)
                return name
        name = f"misc/{len(names)}"
        names.add(name)
        return name

    made = []  # (name, marks, last time), for sub-branches
    worktree_candidates = []
    for _ in range(branch_count(rng)):
        name = branch_name()
        if made and rng.random() < 0.22:
            _, parent_marks, parent_time = rng.choice(made)
            base = rng.choice(parent_marks)
            base_time = parent_time
        else:
            depth = int(min(n - 1, rng.expovariate(1 / max(n * 0.25, 2))))
            base = trunk[n - 1 - depth]
            base_time = times[n - 1 - depth]
        tip_age = rng.choice([rng.uniform(0.1, 6), rng.uniform(6, 40), rng.uniform(40, 115), rng.uniform(125, 300)])
        tip_time = min(max(now - tip_age * DAY, base_time + 3600), now)
        commits = 0 if rng.random() < 0.18 else rng.choice([1, 1, 2, 3, 4, 6, 9, 14, 25])
        if commits == 0:
            # A bud: the branch points at a commit already on the trunk (merged and left behind).
            out.append(f"reset refs/heads/{name}\nfrom :{base}\n\n")
            continue
        marks = []
        parent = base
        for c in range(commits):
            when = base_time + (tip_time - base_time) * (c + 1) / commits
            parent = commit(f"refs/heads/{name}", when, f"{name} {c}", parent=parent)
            marks.append(parent)
        made.append((name, marks, tip_time))
        if rng.random() < 0.12:
            worktree_candidates.append(name)
    stream = "".join(out)
    subprocess.run(["git", "-C", path, "fast-import", "--quiet", "--date-format=raw"], input=stream.encode(), check=True)
    subprocess.run(["git", "-C", path, "symbolic-ref", "HEAD", "refs/heads/main"], check=True)
    subprocess.run(["git", "-C", path, "reset", "-q", "--hard", "main"], check=True)
    return worktree_candidates, rng


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    dest = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 7
    rng = random.Random(seed)
    now = time.time()
    names = TREES[:]
    rng.shuffle(names)
    names += [f"{n}-{k}" for k in range(2, count // len(TREES) + 3) for n in TREES]
    total = sum(WEIGHTS)
    sizes = [max(1, round(count * w / total)) for w in WEIGHTS]
    while sum(sizes) > count:
        sizes[sizes.index(max(sizes))] -= 1
    while sum(sizes) < count:
        sizes[sizes.index(min(sizes))] += 1
    k = 0
    for group, size in zip(GROUPS, sizes):
        for _ in range(size):
            name = names[k]
            path = os.path.join(dest, group, name)
            candidates, r = make_repo(path, seed * 1000 + k, now)
            if candidates and r.random() < 0.6:
                wt = os.path.join(dest, "_worktrees", f"{name}-{candidates[0].replace('/', '-')}")
                os.makedirs(os.path.dirname(wt), exist_ok=True)
                subprocess.run(["git", "-C", path, "worktree", "add", "-q", wt, candidates[0]], check=True)
            k += 1
    print(f"wrote {k} repositories under {dest} ({', '.join(f'{g} {s}' for g, s in zip(GROUPS, sizes))})")


main()
