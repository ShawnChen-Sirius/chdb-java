# Running the concurrent soak on a Linux box

Work plan §5.11 asks for one to six hours of *concurrent* querying. This is how to run it
somewhere other than a laptop, and how to decide first whether the machine can carry it.

## 1. Can this machine run it?

| Requirement | Value | Why |
|---|---|---|
| **glibc** | **≥ 2.28** | the engine package's floor |
| Architecture | x86_64 or aarch64 | both have a pinned engine asset |
| vCPU | **≥ 4** (8 to run the default `--threads 8`) | see the note below — this is the one that ruins results, not just speed |
| RAM | **≥ 2 GB** free, 4 GB comfortable | measured peak: 504 MB RSS, 376 MB PSS, heap capped at 512 MB |
| Disk | **≥ 2 GB** free | engine tarball 146–166 MB, extracted 326 MB, Maven deps ~140 MB, build output |
| Network | needed once | engine tarball + Maven dependencies |
| JDK | 11 or newer | 11 is the driver's floor |
| Maven | 3.9.x | |
| Time | 60 min default | `--minutes` changes it |

**Amazon Linux 2 will not work** — glibc 2.26. Use Amazon Linux 2023 (2.34), Ubuntu 20.04+
(2.31), Debian 11+ (2.31), or RHEL/Rocky 8 (2.28).

Suggested instances: `c6i.xlarge` / `c6g.xlarge` (4 vCPU, 8 GB) with `--threads 4`, or
`c6i.2xlarge` / `c6g.2xlarge` (8 vCPU, 16 GB) for the default. gp3 20 GB.

### The CPU requirement is about correctness, not speed

The harness samples memory every 15 s and judges the trend on those samples. On an
oversubscribed machine the sampler starves and the series becomes unusable — measured on an
18-core host at load average 83, where sample intervals stretched to 385 s, 330 s and 1391 s and
only 11 samples landed in 37 minutes. The memory verdict from that run had to be thrown away.

So: **run it on an otherwise idle machine**, and keep `--threads` at or below half the vCPU
count. The workload itself used about 4.3 cores with 8 workers.

### Preflight — run this before committing an hour

```bash
ldd --version | head -1                      # need >= 2.28
nproc                                         # vCPU
free -g | awk '/Mem:/{print $7" GB available"}'
df -h . | tail -1                             # need >= 2 GB
uptime                                        # load should be near zero
java -version 2>&1 | head -1                  # need >= 11
mvn -v | head -1
```

## 2. Set up

```bash
git clone https://github.com/chdb-io/chdb-java.git
cd chdb-java
git checkout <the branch carrying scripts/run-soak-test.sh>

# Engine + JNI shim for this platform. Downloads ~150 MB and verifies its SHA-256.
bash scripts/build-native.sh "$(uname -m | sed 's/x86_64/linux-x86_64-gnu/;s/aarch64/linux-aarch64-gnu/')"

# Driver classes the probe compiles against.
mvn -q -am -pl chdb-jdbc,chdb-integration-tests test-compile -DskipTests
```

## 3. Run

```bash
# Default: 60 minutes, 8 workers, in-memory database.
bash scripts/run-soak-test.sh --out target/soak/run1

# On a 4 vCPU box:
bash scripts/run-soak-test.sh --threads 4 --out target/soak/run1

# Longer, per the upper end of the gate:
bash scripts/run-soak-test.sh --minutes 360 --threads 4 --out target/soak/run1
```

It runs in the foreground and prints a sample line every 15 s. To leave it unattended:

```bash
nohup bash scripts/run-soak-test.sh --minutes 360 --out target/soak/run1 > soak.log 2>&1 &
tail -f soak.log
```

Useful flags: `--url` (a filesystem path instead of `:memory:`), `--arm pool-drain` (the
deliberately unsafe shape — see §5), `--fault leak|stall` (proves the harness is not empty),
`--runtime <dir>` (a libchdb + shim pair to use instead of the staged one).

## 4. Reading the result

Two files under `--out`: `soak.log` (the report) and `samples.csv` (the series).

```
VERDICT=clean      nothing to do
VERDICT=failed     the reasons are listed under it, with stacks for the first twenty failures
```

The summary worth reading even on a clean run:

- **`TOTAL unexpected failures`** — the allowance is 0. Anything here is a driver bug.
- **`engine restarts observed`** — must be 0. If it is not, the run measured chdb-core's
  allocator-churn problem rather than this driver, and the numbers mean nothing (see §5).
- **`handles after the pools closed`** — must be `0/0/0`.
- **the slope table** — `phys_footprint` is the honest column. RSS counts pages of the 326 MB
  engine image as they fault in and does not count compressed pages, so it can fall while real
  usage grows; that happened in calibration, RSS stepping down 120 MB while footprint stayed flat.
- **sample count per row** — if `phys_footprint` has only a handful of points over the window,
  the sampler was starved and the memory verdict is not trustworthy. Re-run on a quieter box.

## 5. Why the harness pins a connection, and what `--arm pool-drain` is for

chdb-core's own test infrastructure records that repeatedly starting and tearing down the
embedded engine in one process can corrupt the process allocator on macOS, and shards its suite
into subprocesses to stay under that. Their measurements: two path-switching restarts in one
process reproduce it at 1/10; bare restart loops (same path ×30, fresh path ×40, with MergeTree
tables ×25) do not reproduce at all. It needs accumulated state *and* repeated restarts.

A connection pool reaches that shape whenever it drains to zero and re-opens. So the soak holds
one connection open for the whole window, outside the pool, and reports `engine restarts
observed: 0` to prove the engine booted once. Without that, a crash could not be attributed.

`--arm pool-drain` is the opposite: it deliberately lets the pool empty. It exists because a real
application can be configured that way — `minimumIdle=0` is common, and HikariCP's 30-minute
`maxLifetime` can briefly empty a pool even with `minimumIdle >= 1`. Treat a failure there as the
known upstream constraint, not as a driver bug.

## 6. What it covers

Eleven shapes mixed across the workers: streaming reads to exhaustion, materialised reads
(`SHOW` / `DESCRIBE` / `EXPLAIN`), early `ResultSet.close()`, cascading `Connection.close()` with
statements still open, `Statement.cancel()`, `setQueryTimeout` firing during the open and during
the fetches, prepared statements with bound parameters, DDL/DML, metadata calls, and statements
the engine rejects. One completed hour on macOS arm64 was 11 860 iterations and 309 million rows.
