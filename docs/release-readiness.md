# Getting to a published release

What stands between the current `main` and an artifact on Maven Central, who has to do each
part, and which parts need someone else's approval.

Written as three separate tracks because they proceed independently and have different
blockers: **signing and publishing** is mechanical and self-service, **the namespace** needs
DNS access, and **licences** need a person with authority to say yes.

`docs/publishing.md` is the reference — the release profile, the namespace claim, the
publishing limits, the licence inventory — and is the only place any of those numbers live.
This file is the **running order and the state**: what is left, in what sequence, and how to
know each step worked. Where the two could disagree, this one points there rather than
restating.

---

## Running order

The tracks below say *what* and *who*. This says *when*, because each step can invalidate the
next. Eight steps. Four of them need somebody outside this repository — 1 needs DNS access to
`chdb.org`, 2 may need Sonatype support, 5 needs chdb-io, and 6 needs two projects willing to
depend on us — so those are the ones to start asking about early. Steps 3, 4, 7 and 8 are
self-service.

### 1. Claim the `org.chdb` namespace — needs DNS access to `chdb.org`

Register at <https://central.sonatype.com>, start a namespace claim for `org.chdb`, and hand
the TXT record Sonatype names to whoever administers the `chdb.org` zone. Verified
automatically, no human review, no queue. §1.3 has the detail, including why there is no
fallback.

**Done when:** `org.chdb` shows as verified in the portal.

### 2. Read the Usage Center, and ask for an exception if the numbers are tight

Enforcement of the organisation-level publishing limits starts 1 October 2026.
`docs/publishing.md` §4 has our measured numbers and the text of the case to make.

**Done when:** <https://central.sonatype.com/publishing/usage> has been read, and **either** the
numbers there are comfortably inside the thresholds **or** Sonatype has granted an exception
that covers the numbers we actually publish.

Not "an email has been sent", and not "Sonatype replied" — a refusal is a reply, and so is a
request for more detail. Either of those leaves the release liable to be rejected at upload
time, which is the thing this step exists to find out about in advance. If the answer is no,
that is a real finding and the next question is what to do about ~510 MB in a release month,
not whether to carry on.

### 3. Decide whose GPG key signs, generate it, and load the CI secrets

§1.2 for the decision, which is not technical. Then four secrets, in a GitHub environment named
`maven-central` so `.github/workflows/release.yml`'s deploy job can require a reviewer:

| Secret | What |
|---|---|
| `GPG_PRIVATE_KEY` | the ASCII-armoured private key |
| `GPG_PASSPHRASE` | its passphrase |
| `CENTRAL_TOKEN_USERNAME` | portal token username |
| `CENTRAL_TOKEN_PASSWORD` | portal token password |

**Done when:** `release.yml` run with `channel=snapshot` and `dry_run=true` produces a `.asc`
for every artifact. That exercises staging on all four platforms, signing and packaging, and
uploads nothing.

### 4. Enable SNAPSHOTs for the namespace and publish a snapshot

Snapshot publishing is opt-in per namespace — **Enable SNAPSHOTs** in the portal, or the upload
is rejected. Then `release.yml` with `channel=snapshot` and `dry_run=false`.

Worth doing before any release polish. §1.5 says what it answers that nothing local can.

**Done when:** the snapshot resolves from
`https://central.sonatype.com/repository/maven-snapshots/` in a project that is not this one.

### 5. Get the licence position on the engine — needs chdb-io

Track 2. Inherit the position taken for the existing PyPI and npm distributions of the same
`libchdb.so` rather than deriving one here.

**Done when:** there is a written answer from someone who can give it, and whatever notice it
requires ships in `META-INF/licenses/`.

### 6. Have two external projects consume the snapshot

The V1 gate, and the reason step 4 comes before the release polish. Candidates worth asking: a
chDB cookbook example, the ADBC driver work, any internal tool that wants an embedded
analytical engine on the JVM.

**Done when:** two projects outside this repository depend on a published coordinate, and what
broke is written down. The value of this gate is that list.

### 7. Run the concurrent soak

Work plan §5.11: one to six hours of *concurrent* querying. Blocking — see §3.1, which says why
a single-threaded run does not discharge it, and §3.1.1 for the harness, the numbers from the
first long run, and the one thing that run found.

```bash
mvn -pl chdb-jdbc -am compile && scripts/build-native.sh <platform>
scripts/run-soak-test.sh --minutes 75              # or the Actions tab: the `soak` workflow
```

**Once per release, not once ever.** The mechanisms the soak covers — the execution gate, the
shim's lock order, the timeout execution number — are exactly the ones a bug fix in the
concurrent path perturbs, and the whole point of the gate is that a short test does not see
what an hour of load sees. So a release runs it on the commit being released, not on whichever
commit last passed it.

**Done when:** the run exits 0 on the release commit, and its numbers are written into §3.1.1
next to the previous run's. A run that dies with a signal and no `hs_err` has not failed the
gate so much as hit §3.1.1's open question — the script says so when it happens — and the
decision recorded there has to be made before the release, not around it.

### 8. Cut the release

```bash
# The version lives in git, not in CI: the tag has to name bytes a commit describes.
mvn versions:set -DnewVersion=<release version> -DgenerateBackupPoms=false
git commit -am "release <release version>"
git tag -a v<release version> -m "..."
git push origin main                        # let build.yml go green on the commit first
git push origin v<release version>
```

`release.yml` then stages each platform on its own runner, reassembles the four in one deploy
job, signs, and uploads a bundle that **waits in the portal**. Confirm it by hand at
<https://central.sonatype.com/publishing/deployments>: a release cannot be unpublished.

Before it stages anything it refuses to continue unless the POMs are at a non-`SNAPSHOT`
version, a tag named `v<that version>` exists and points at the commit being built, and
`build` concluded successfully for that same commit. The tag check applies to a manual
`channel=release` run too, so there is no path that publishes an untagged commit, and it runs
a second time as the last step before Maven publishes.

**Protect the release tags, once, before the first release.** The second check exists because
staging takes ten minutes and more and the `maven-central` approval gate can hold a run for
much longer, and a tag can be force-moved or deleted inside that window — so a run could
otherwise publish one commit under a version whose tag now names another, permanently. Checking
twice shrinks that window to the seconds between the last check and the upload; it does not
close it. Closing it is an organisational setting rather than a workflow one:

- a tag protection rule on `v*` in the repository's rulesets, forbidding update and deletion,
  which makes a release tag immutable once pushed;
- and, if the plan is releases from `main` only, restricting who can create those tags.

Do this as part of step 3, when the `maven-central` environment is being set up, because it is
the same conversation with the same person. The workflow does not verify that the rule exists —
it cannot tell a protected tag from an unprotected one — so it is on this checklist rather than
in CI.

Afterwards, the ordinary "back to development" commit returns the POMs to a `-SNAPSHOT`.

---

## Track 1 — Signing and publishing mechanics

**Nobody's approval needed. All of it can be done by whoever holds the repository and one DNS
record.**

### 1.1 What Maven Central requires, and where we stand

Checked against the current `main`. An earlier version of this table listed all of the first
seven rows as absent; they were built in #13 and this is the state after it.

| Requirement | Status |
|---|---|
| `sources` JAR | **done** — a real one for `chdb-jdbc`, empty by construction for the native packages |
| `javadoc` JAR | **done**, same split |
| GPG signature (`.asc`) per file | **done**, verified end to end with a disposable key |
| `<scm>` in the POM | **done** |
| `<developers>` in the POM | **done** |
| `<licenses>` | **done** |
| `<name>`, `<description>`, `<url>` | **done** |
| Publishing plugin | **done** — `central-publishing-maven-plugin`, `autoPublish=false` |
| Third-party licence inventory | **done**, generated from the engine and drift-tested |
| Refusal to package an unstaged or `--local-engine` native module | **done** |
| A way to stage all four platforms for one release | **done** — §1.6 |
| Proof the artifacts work when consumed from a repository | **done locally** — §1.5 |
| Portal token in a CI secret | **not started** — running order step 3 |
| A GPG key that is the project's rather than a laptop's | **not started** — §1.2 |
| `org.chdb` namespace | **not started**, and the one item with no workaround — §1.3 |

So the mechanics are finished and the remaining items in this track are two credentials and
one DNS record. `docs/publishing.md` §1 is the runbook for what the profile does.

### 1.2 The GPG key — self-service, but decide whose key it is

Generating a key needs no approval:

```bash
gpg --full-generate-key          # RSA 4096, no expiry or a long one
gpg --list-secret-keys --keyid-format=long
gpg --keyserver keyserver.ubuntu.com --send-keys <KEY_ID>
gpg --keyserver keys.openpgp.org  --send-keys <KEY_ID>
```

Central verifies the signature against a public keyserver, so the public half must be
published to at least one and propagation takes a few minutes.

**The decision that is not technical:** whose key signs chdb-io's artifacts. A personal key
means releases stop when that person is unavailable and the key follows them if they leave. A
project key shared through the CI secret store is the usual answer for an organisation, at the
cost of the key being only as protected as the secret store.

Whichever is chosen, CI needs two secrets — the ASCII-armoured private key and its passphrase.
`maven-gpg-plugin` is already bound to `verify` in the release profile, and
`.github/workflows/release.yml` imports the key through `setup-java`, so the only outstanding
part is the key itself and the four secrets in running-order step 3. Signing locally on a
laptop for the first release is fine and is the faster path to finding out whether the rest
works.

### 1.3 The namespace — needs DNS access, approved automatically

`org.chdb` is **unclaimed**: Maven Central returns zero artifacts for it, and for `io.chdb`,
`com.chdb` and `io.github.chdb-io` as well. So there is no conflict to resolve, only a claim to
make.

Verification is by DNS. `chdb.org` resolves (13.248.169.48), so whoever administers that zone
adds a TXT record Sonatype names during registration, Sonatype's checker sees it, and the
namespace is granted. No human review, no waiting on a queue.

**There is no fallback, contrary to what an earlier version of this section said.** It offered
`io.github.chdb-io`, verified by creating a repository under the `chdb-io` GitHub org. That is
not available; Sonatype's wording, quoted in `docs/publishing.md` §3, is that only the GitHub
username used to sign up is supported, so `io.github.<organisation>` cannot be registered
automatically. GitHub verification would grant `io.github.<maintainer-username>` — a personal
coordinate, and the wrong thing to publish an organisation's driver under.

**So DNS access to `chdb.org` is a hard prerequisite**, not a convenience, and it is worth
confirming who has it before anything else in this document is started. `org.chdb` is also the
coordinate already in every POM, README and document; changing it later is a breaking change
for consumers.

**Action:** register at <https://central.sonatype.com>, start the `org.chdb` namespace claim,
and hand the TXT record to whoever runs `chdb.org` DNS.

### 1.4 Publishing limits — check the org's standing before the first release

Maven Central introduced organisation-level limits on **file count**, **release size** and
**release count**, informational since 16 June 2026 and **enforced from 1 October 2026**.

**The numbers, the percentile table and the case to make are in `docs/publishing.md` §4 and
only there.** An earlier version of this section reproduced them and got the measurement window
wrong — it described a rolling three-month average and then reasoned that a 2–3 month cadence
divides the release size by two or three. Sonatype is explicit that each metric resets at the
start of the month and is compared directly against that month's threshold, not averaged, so
a slower cadence does not make a release month cheaper; it makes the other months empty. Two
copies of a number is how that kind of error survives, which is why this file now keeps none of
them.

The shape of the answer, from that section: release size is the only metric in play, we are
around the 97th percentile on it in a release month and near the floor on the other two, and
what enforcement actually looks for is sustained rather than occasional usage — which an
event-driven release every two to three months is not.

**Action, and it is cheap:** log into the Usage Center at
<https://central.sonatype.com/publishing/usage> once the namespace exists and read the real
numbers. If they are tight, email `central-support@sonatype.com` before the first release
rather than after a rejection, with what the exception form asks for; `docs/publishing.md` §4
has the wording. Sonatype's own documentation says exceptions are granted as a permanent
adjustment once the pattern is understood.

**One thing to confirm rather than assume:** from 1 October 2026, artifacts of a *commercial
nature* require Maven Central Publisher Pro regardless of volume. Whether chDB counts is a
question for whoever owns the relationship, not a technical one.

### 1.5 What to do first, and what it is still for

Publish a **snapshot**, before any of the release polish. That has not changed. What has changed
is why: most of what a snapshot was going to find can now be found locally, in a few minutes,
without publishing anything.

```bash
scripts/verify-consumer.sh
```

It deploys to a throwaway `file://` repository, builds a consumer project outside this checkout
with its own empty local repository, imports the BOM, declares exactly one platform package with
no version, and runs a query. It asserts that the POMs resolve from a repository, that the BOM
supplies the versions, that `chdb-jdbc` arrives transitively, that the libraries are unpacked
from the JAR rather than read from `target/`, that their checksums match what
`scripts/build-native.sh` staged, and that the "no platform package" and "wrong platform
package" errors each name the coordinate the machine actually needs. `build` runs it on all
four platforms, so the answer cannot go stale between releases.

**What the gate found on its first run**, which is the part issue #10 asks for:

- The BOM import and the transitive `chdb-jdbc` dependency were already right, and are now
  asserted rather than assumed.
- **A snapshot deploy does not write the filenames a reactor build uses.** It writes
  `chdb-jdbc-<version>-<timestamp>-1.jar` plus a `maven-metadata.xml` that maps `-SNAPSHOT` onto
  that timestamp; without the metadata a consumer gets a 404 for a version that is demonstrably
  there. Nothing exercised that indirection before. The consumer's *local* repository then ends
  up holding both names at once — the timestamped file it downloaded and a `-SNAPSHOT.jar`
  beside it — so anything that looks for the driver by file name is depending on a resolver
  detail. `scripts/verify-consumer.sh` locates it by coordinate, `org/chdb/chdb-jdbc/`, for
  that reason.
- **"Declared the wrong platform package" was indistinguishable from "declared none".** Both
  produced the same message — three locations searched, none found, here is the coordinate to
  add. The advice is right either way, but somebody looking at
  `chdb-native-linux-x86_64-gnu` in their own POM while being told to add a platform package
  has no way to work out what they did wrong. The loader now names the `chdb-native-*` packages
  that are on the classpath when they are for another machine. This was the one real defect the
  gate found.
- **`central-publishing-maven-plugin` was configured with a parameter it does not have.**
  `waitUntilValidated` is not a parameter of version 0.11.0; the mojo declares `waitUntil`,
  `waitMaxTime`, `waitPollingInterval` and `waitForPublishCompletion`. Maven drops configuration
  elements a mojo does not declare rather than failing on them, so it had been doing nothing.
  Now `<waitUntil>VALIDATED</waitUntil>`, which is also the default — so the behaviour was
  right by accident, and a release run reporting "validated" now means it.

**What is left for a real snapshot** is one thing, and it is the reason to still do it early:
whether a 98–166 MB artifact survives an upload and a download over the network. A `file://`
deploy is a copy, so it cannot fail the way a transfer can.

### 1.6 Assembling all four platforms — done, in CI

A release needs all four platform packages staged in one working directory and no machine can
produce them: `scripts/build-native.sh` refuses to cross-build on purpose, and `macos-x86_64`
needs an Intel Mac. `.github/workflows/release.yml` stages each platform on its own runner,
uploads `target/native/` as an artifact, and downloads all four into one deploy job that runs
`mvn -Prelease deploy`. It publishes snapshots from the same jobs, so the release path is
exercised long before a release depends on it.

The workflow's header records the three decisions behind it, including the measured answer on
build reproducibility: the engine half is reproducible because it is pinned by SHA-256, and the
shim's `__text`, `__cstring`, `__const` and `__data` reproduce byte for byte while `LC_UUID`,
four debug-map timestamps and the ad-hoc code signature do not. Nothing in the release gate
depends on that, and the workflow records the SHA-256 of everything it shipped instead.

---

## Track 2 — Licences

**This one needs a person with authority. The engineering part is small; the sign-off is not
ours to give.**

### 2.1 Our own code

`chdb-java` is Apache-2.0, written here, and `LICENSE` is in the repository. Nothing to do.

### 2.2 The redistributed engine — inherited, not new

Each platform package ships `libchdb.so` verbatim from a chdb-core release, and that library
statically links the ClickHouse tree.

**The inventory of what is inside it, and the licence of each component, is in
`docs/publishing.md` §5 and only there.** An earlier version of this section counted 156
contrib submodules by scanning their licence files and found seven LGPL and eight GPL. That
method has since been replaced by querying the binary we actually ship —
`SELECT DISTINCT library_name, license_type FROM system.licenses`, which ClickHouse generates
at build time — and the answer is 968 components, of which twelve carry a copyleft licence
with no permissive alternative, in two families rather than one. A filename scan calls every
dual-licensed component GPL and describes a source checkout rather than an artifact, so the
older numbers should not be reasoned from; the result is committed at
`licenses/engine-third-party-<version>.tsv`, shipped in the package, and guarded by
`LicenseInventoryIT`, which fails if it stops matching the engine.

What is unchanged, and is the point of this track: LGPL carries obligations under **static**
linking that it does not under dynamic, and `libchdb.so` links everything statically — its only
shared dependencies are `libc`, `libm`, `libdl`, `librt`, `libpthread` and the loader.

**The decisive point: this is not a new question.** The identical `libchdb.so` is already
redistributed on PyPI and npm by chdb-io. Whatever notice and offer-of-source obligations
attach, attach there too, and someone has already had to answer them — or has not, in which
case the Java package is not where that gets discovered.

So the task is **inherit and verify**, not analyse from scratch:

1. Ask chdb-core maintainers for the notice bundle their PyPI and npm releases ship, and what
   position was taken on the copyleft components. If there is one, mirror it.
2. If there is not, that is a finding about all three distributions and should be raised as
   such rather than solved inside this repository.

### 2.3 What we already produce mechanically

`scripts/build-native.sh` creates `META-INF/licenses/` with our licence, a README pointing at
the engine's release and the generated third-party inventory, plus `META-INF/sbom/bom.json` in
CycloneDX form listing both libraries with their checksums. This section previously described
the inventory as a gap and estimated half a day for it; it is done, and
`docs/publishing.md` §5 says how to regenerate it after an engine bump.

### 2.4 Who decides what

| Item | Who | Approval needed |
|---|---|---|
| Apache-2.0 on our own code | already done | no |
| Generating and publishing a GPG key | any maintainer | no |
| `org.chdb` namespace claim | whoever runs `chdb.org` DNS | automatic once the TXT record is up |
| Shipping the engine's licence inventory | already done | no |
| **Whether redistributing `libchdb.so` under Apache-2.0 discharges the obligations of the twelve copyleft components** | **chdb-io / ClickHouse legal** | **yes, and it is the only real gate in this track** |
| Whether chDB counts as "commercial nature" for Central | whoever owns the Sonatype relationship | yes |

---

## Track 3 — What is still untested

Two of these **block a release** and the rest do not, so they are in separate tables. An
earlier version of this section put the soak test in one table with the optional work and then
described the whole table as parallel and non-blocking, which let an operator read past a
required gate on the way to the sentence saying the gate was required.

Everything in §3.2 needs only time and nobody's permission. Of the two in §3.1, the soak needs
only time; external consumption needs other people, which is why it is also running-order
step 6.

### 3.1 Blocking — a release does not go out without these

| Gate | What it requires | Effort |
|---|---|---|
| **Concurrent soak, 1–6 hours** | Work plan §5.11 asks for a *concurrent* soak, not a single-threaded loop: several connections on several threads for the whole window, with the RSS/PSS slope recorded across it. A sequential run measures allocator behaviour and nothing else. The milestone it is there to discharge is that cancel, timeout, early close and cascading `Connection` close "leak nothing and never deadlock" — and a deadlock cannot occur, so cannot be ruled out, in a single thread. `scripts/run-soak-test.sh` now exists and has been run; **§3.1.1 has the numbers, and the reason this row is still marked blocking.** | harness done; an hour per release, and one open question |
| **External consumption of a published artifact** | The gate says two projects outside this repository. `scripts/verify-consumer.sh` closes the mechanical half locally (§1.5); this is the half that needs other people, and running-order step 6 is where it sits. | depends on others |

### 3.1.1 The soak harness, and what it found

`scripts/run-soak-test.sh`, with the driver at `aa8e0c7`, on macOS 26 / arm64 (18 cores, 36 GB)
against the pinned v26.7.2-rc.2 engine on Java 21. `.github/workflows/soak.yml` is the same
thing on demand or weekly, and deliberately **not** on push: an hour-long job per commit would
make the pipeline useless for what it is for.

**The shape.** `HikariPoolIT`'s, scaled up in time — a pool, eight worker threads, and a
connection *per query* rather than per thread, because a connection per query is what churns
the storage-path registry and the per-connection statement slot hardest. A quarter of the
iterations go to `DriverManager` instead of the pool, which is not variety for its own sake: a
pooled `Connection.close()` never reaches the driver's cascade, because HikariCP closes the
tracked `Statement`s itself on the way back to the idle set. The cascade shape has to be
unpooled to test anything.

**The engine boots once, and that is measured.** This is the premise of the whole run, because
the alternative measures somebody else's bug. chdb-core's test runner records that "starting and
tearing the embedded engine down on every connection repeatedly can corrupt the process
allocator and abort under load on macOS", and is built around avoiding it: a process to itself
for any test opening a non-`:memory:` path, and the rest split across four processes "so that no
single process accumulates the whole suite's engine create/destroy churn". Their numbers say it
takes accumulated state *and* repeated restarts — two state-accumulating suites sharing a
process crashed 1 run in 10, each alone 0 in 10, and a bare restart loop did not reproduce it in
30, 40 or 25 attempts.

The engine is booted by the connection that finds none open and torn down by the last one to
close. `StoragePathRegistry` does not do that — it is bookkeeping over a key and a count, and
its only action at zero is to let a *different* path bind next. The teardown is the engine's own,
triggered by `chdb_close_conn` on the last connection, which is why the driver documents the
`:memory:` database as living "until the last connection closes".

The first version of this harness therefore had it backwards. It set `minimumIdle=0` with a
20-second idle timeout *on purpose*, to churn the storage-path registry — which arranged for the
engine to restart repeatedly, and would have made any crash indistinguishable from the known
upstream shape. The `steady` arm now holds one connection open for the whole window, taken
before the pool exists and released after the last worker stops, outside the pool so that no
pool setting can retire it. Measured on a three-minute steady run:

```
engine-floor samples (every 5 ms)                          29257
of those, zero connections open (engine down)                  0
engine restarts observed (0 -> 1 transitions)                  0
lowest connection count seen                                   3
```

and the verdict fails a steady run that ever reaches zero, so this cannot quietly stop being
true.

**`--arm pool-drain` keeps the dangerous shape, deliberately and separately**, because it is
what real users hit: `minimumIdle=0` is the ordinary setting for a low-traffic service, and
after a lull the pool releases everything and the next request restarts the engine. The arm
cycles ten seconds of load against five of quiet against a one-second idle timeout, so the pool
really empties. A crash there is the known upstream hazard, not a driver defect, and it is
labelled so nobody has to guess. `docs/unsupported.md` tells users to keep `minimumIdle >= 1`
and why.

**The integration suite is inside that shape too**, which is worth writing down. `HikariPoolIT`
uses `minimumIdle(0)` and builds a fresh pool per test method inside try-with-resources, so each
method closes every connection it opened — one engine boot and teardown apiece, and the suite
runs every IT class in one JVM per JDK. It is green today, so the accumulated churn is evidently
below upstream's threshold, but it is the first thing to look at if the suite ever starts dying
with a signal and no `hs_err`.

**And it gives a way to tell the two crash modes apart**, which matters for the one crash this
work produced (below):

| | issue #14, the signal window | upstream allocator corruption |
|---|---|---|
| Signal | SIGSEGV or SIGBUS, whatever HotSpot handles for itself | abort — SIGABRT |
| Crash report | **none**, because the handler that writes it is the one that was removed | normal: `hs_err` or an `.ips` |
| Needs | concurrent `chdb_connect` calls | repeated engine restarts plus accumulated state |
| Corroborated by | `run-signal-window-test.sh measure` reporting a non-zero count | engine restarts observed > 0 |

**The mix**, weighted rather than uniform, because the shapes cost between a millisecond and
several seconds and a uniform draw would spend the window on the expensive ones:

| Shape | What it is for |
|---|---|
| `stream-full` | a streamed `SELECT` read to exhaustion, 20k–200k rows, row count asserted |
| `stream-early-close` | `close()` on a result set with a hundred million rows left to produce |
| `cascade-close` | `Connection.close()` with an open `Statement` and `ResultSet` under it, unpooled |
| `materialized` | `SHOW`, `DESCRIBE`, `EXPLAIN`, `EXISTS`: the `chdb_query_arrow_n` route |
| `prepared` | `PreparedStatement` with four bound parameters |
| `ddl-dml` | `CREATE` / `INSERT` / `SELECT` / `TRUNCATE`: the no-result-set route |
| `error` | a statement the engine rejects, then a query on the same connection |
| `metadata` | `DatabaseMetaData.getTables` and `getColumns`, which run their own queries |
| `cancel` | `Statement.cancel()` from another thread, 40–240 ms into a fetch |
| `timeout-stream` | `setQueryTimeout(1)` expiring during `next()` |
| `timeout-open` | `setQueryTimeout(1)` expiring inside the uninterruptible open |

**And it watches `phys_footprint`, not only RSS.** On this platform RSS is actively misleading:
it counts engine image pages as they are faulted in, and does not count pages the compressor
has taken, so it stepped *down* 120 MB two minutes into the calibration run while the process
was getting busier. `phys_footprint` — the kernel's ledger of what is charged to the task — sat
flat within 2 MB across the same stretch. On Linux the column is `Pss` from `smaps_rollup`,
which is the number work plan §5.11 actually names.

**What the run measured.** 75 minutes, eight workers, `jdbc:chdb::memory:`, everything above in
the mix. Slope and ceiling are both over the last 80% of the window, because the engine warms up
in the first fifth — it faults in its image, fills its caches and settles — and a statistic that
includes warm-up measures warm-up:

| Series | Slope | Ceiling, first half → second half |
|---|---|---|
| RSS | −68.88 MB/h | 572.53 → 560.17 MB (**−12.36**) |
| `phys_footprint` | +93.42 MB/h | 589.47 → 593.38 MB (**+3.91**) |
| JVM heap used | +28.04 MB/h | 306.13 → 306.83 MB (+0.70), against a 512 MB cap |
| Native handles | +0.27/h | 15 → 16, and **0/0/0 after the pools closed** |

482,442 iterations, 12,489,675,470 rows read, **zero unexpected failures**, and every shape in
the mix ran: 105,848 full streams, 86,659 materialized reads, 67,813 early closes, 67,194
unpooled cascading closes, 48,427 parameterised statements, 29,189 DDL/DML cycles, 29,119
rejected statements, 23,966 cancels that actually cancelled, 9,722 timeouts that fired during
`next()`, 9,577 that fired on the open's deadline, 4,928 `DatabaseMetaData` sweeps.

**Why the ceiling and not the slope, which is a correction.** The harness originally asserted a
least squares slope, and this run failed it: `phys_footprint` fitted at **+93.42 MB/h** against
a 25 MB/h threshold, while RSS over the same window *fell* at 68.88 MB/h and the handle count
was flat. Investigating rather than raising the threshold showed the fit was the problem.

Here is the series that failed it, as two-minute means in MB:

```
  0m 472   2m 522   4m 584   6m 590   8m 595  10m 531
 12m 581  14m 551  16m 524  18m 486  20m 483  22m 482
 24m 472  26m 486  28m 474  30m 470  32m 519  34m 583
 36m 584  38m 587  40m 589  42m 589  44m 589  46m 592
 48m 592  50m 592  52m 592  54m 593  56m 593  58m 593
 60m 542  62m 543  64m 587  66m 541  68m 527  70m 554
 72m 585  74m 585
```

That is not growth and it is not a warm-up step. It is **a cache filling to a ceiling, being
trimmed, and refilling to the same ceiling** — 595 at minute 8, down to 470 by minute 30, back
to 592–593 and sitting there from minute 46 to 58, then wobbling. The high-water mark is stable
to about a megabyte across the whole run. A least squares fit over a window that happens to
start in the trough (minutes 15–30) and end on the plateau (minutes 58–75) *must* come out
positive; it is measuring where the trim fell relative to the window boundaries. Same data,
three windows:

```
whole run    +46.48 MB/h
last 80%     +93.42 MB/h     <- what the run was failed on
last 50%     -68.16 MB/h     <- the opposite conclusion
```

**So why is the ceiling the right statistic, and does it still catch a slow leak?** Yes, and
better than the slope, for three reasons.

1. *A leak raises the ceiling by construction.* Leaked bytes are not returned by a trim, so they
   sit under everything the cache holds. The moment the cache is full is the moment leaked bytes
   are most visible, not least — the maximum is where a leak shows up first.
2. *Its noise floor is far tighter.* Across two independent long runs the ceiling moved −12.4
   and +3.9 MB, while the slope on the *same* series ranged from −68 to +93 MB/h depending only
   on where the window was cut. A criterion is only as sensitive as its noise, and the ceiling's
   is roughly twenty times smaller.
3. *It is not sensitive to window placement at all*, which is what made the slope unusable here:
   the trim cycle is minutes to tens of minutes long, comparable to the window itself.

**Its sensitivity, stated rather than assumed.** A leak is caught when it lifts the ceiling more
than the 32 MB threshold *within the window*. At the 482,442 iterations this run did in 75
minutes that is about **70 bytes per iteration**. Below that the memory ceiling will not see it
on an hour-long window — a 5-byte-per-iteration leak needs roughly seven hours to lift the
ceiling 32 MB — which is precisely what the work plan's "one to six hours" is for, and why a
release runs the longest window it can afford rather than the shortest that passes.

What covers the gap under 70 bytes an iteration is the handle counter, which is why it is the
primary signal: a leaked `ResultSet`, `Statement` or `Connection` is caught at *any* size,
because it is counted rather than weighed, and the end-of-run check that all three counts are
zero has no threshold at all. A leak that leaks memory but no handle, at under 70 bytes an
iteration, is the one thing this gate would need a multi-hour window to see. That is a real
limitation and it is recorded here rather than papered over.

Highest value in the first half of the fit window against the highest in the second, on the
recorded series:

```
75-minute clean run       rss  -12.4 MB   phys_footprint   +3.9 MB   handles  +1
10-minute clean run       rss   +0.2 MB   phys_footprint  -34.2 MB   handles  +2
10-minute leak fault, 1   rss  +51.1 MB   phys_footprint +234.1 MB   handles +41
10-minute leak fault, 2   rss  +27.3 MB   phys_footprint  +67.0 MB   handles +33
```

A separation that, unlike the slope, does not depend on window placement. The threshold is
32 MB: eight times above the largest clean measurement, and two to seven times below the fault
depending on where in its own oscillation the leak run happens to end. At 482,442 iterations per
75 minutes it is still enough to catch a leak of about 70 bytes an iteration.

The spread between the two fault runs is the reason the handle counter carries most of the
weight and the memory ceiling is a backstop rather than the primary signal: 32 MB is a
comfortable margin against a leak of engine memory and a thin one against a leak of only a few
tens of megabytes.

**The handle thresholds were wrong for the same reason, and it took a second failing run to
see it.** The handle slope started at 0.50/h — "half a handle an hour, surely generous" — and a
clean 66-minute run failed it at **+0.53/h**, with both memory ceilings falling, zero unexpected
failures, and handles back to 0/0/0 at the end. The live count is not monotone either: the pool
opens and evicts connections on its own schedule, so it wanders between 7 and 17 across a
window. For a counter swinging by ten over fifty minutes with 69 samples, one standard error on
the fitted slope is about 1.4/h — so a 0.50/h threshold sat well inside the statistic's own noise
and was always going to flake. Measured over every run long enough to fit:

```
clean, 66 minutes     slope   +0.53/h    ceiling 14 -> 17  (+3)
clean, 75 minutes     slope   +0.27/h    ceiling 15 -> 16  (+1)
clean, 10 minutes     slope  -10.24/h    ceiling            (+2)
leak fault, run 1     slope +410.19/h    ceiling 55 -> 96  (+41)
leak fault, run 2     slope +560.29/h    ceiling 70 -> 103 (+33)
```

So the slope threshold is 25/h — about eighteen standard errors above the noise and sixteen
times below the smallest fault — and a handle *ceiling* threshold of 16 was added alongside it,
five times above the largest clean rise and twice below the smallest fault. Both are asserted,
because each covers the other's blind spot: the ceiling is deaf to a slow climb that never
exceeds the pool's high-water mark, and the slope is noisy on a counter that swings by ten.

Neither is the primary defence. That is the unconditional check that all three handle counts are
zero once the pools have closed — no threshold to get wrong, the same assertion `NativeTestBase`
makes after every test, and the one the leak fault failed at 45/0/45. The window statistics
exist to catch a leak that something happens to clean up before the end.

The slopes are still computed and printed, because they are the right first thing to look at
when something has moved; for memory they are diagnostics rather than the gate.

**Two corrections is the honest count.** Both were the same mistake — a threshold picked by
intuition on a statistic whose noise had not been measured — and both were caught by a clean run
failing rather than by a dirty one passing, which is the safe direction for that mistake to go.
Every recorded series was re-judged under the final thresholds with `--analyze`: all four clean
runs pass, both leak faults fail on the memory ceiling *and* the handle ceiling, and the two
stall runs fail on having too few samples to fit, which is what they should say — they are
judged by exiting 3, not by a regression.

**The order of events**, because a threshold changed after a failing run deserves it:

1. a 75-minute window ran and produced the series above; it failed the memory criterion the
   harness shipped with at the time;
2. the memory criterion was changed to the ceiling, and the three fault modes re-run under it;
3. a 66-minute window ran and came back clean on memory — and failed the handle *slope* at
   +0.53/h against 0.50/h;
4. the handle thresholds were corrected the same way, and every recorded series re-judged.

`scripts/run-soak-test.sh --analyze <dir>` is what re-judges a recorded `samples.csv`. It exists
because the series is the evidence and a threshold is a judgement about it, and those change on
different schedules — so a correction like this one does not need the run repeated to find out
what the new statistic says about the old data, and a CI artifact from three weeks ago stays
worth reading.

**The two long windows in numbers**, so nothing above has to be taken on trust:

| | 75 minutes | 66 minutes |
|---|---|---|
| Iterations | 482,442 | 132,633 |
| Rows read | 12,489,675,470 | 3,462,714,985 |
| Unexpected failures | 0 | 0 |
| Handles after the pools closed | 0/0/0 | 0/0/0 |
| RSS ceiling | −12.36 MB | −2.39 MB |
| `phys_footprint` ceiling | +3.91 MB | −105.02 MB |
| Handle ceiling | +1 | +3 |
| Handle slope | +0.27/h | +0.53/h |

The 66-minute run did a quarter of the iterations of the 75-minute one for the same wall clock,
because the host it ran on was contended: two five-minute windows where throughput collapsed
appear in its `samples.csv` as 320-second and 313-second gaps between samples. Worth recording
for two reasons. The memory series was unaffected — RSS moved 0.2 MB across the first gap — and
the watchdog correctly stayed quiet, because every worker kept completing iterations through it.
Slow is not stuck, and a progress counter is what can tell the difference.

**Deadlock detection is a progress counter, not the run timeout.** A run killed by its own
deadline tells you it hung and nothing else. Each worker bumps a counter per iteration and a
watchdog checks every ten seconds that all of them have moved inside the stall window; on a
stall it dumps every Java thread and every native frame and exits 3. It also polls
`ThreadMXBean.findDeadlockedThreads`, which is immediate but sees only monitor cycles — it
cannot see a `StatementSlot` semaphore or a `std::mutex` in the shim, which is what the
progress counter is for.

**The harness was shown to go red before the clean run was believed.** A soak that has never
failed proves only that the process did not crash, so all three detectors were driven by an
injected fault, and `soak.yml` re-drives them weekly and checks that each fails for its own
reason rather than merely failing:

| `--fault` | What it does | What caught it, measured |
|---|---|---|
| `leak-resultset` | abandons one `Connection` + `Statement` + `ResultSet` every 40 iterations, 45 of them over ten minutes | three signals, independently: **45/0/45 handles open after the pools closed**, a `phys_footprint` ceiling rise of **+66.98 MB** against the 32 MB threshold, a handle slope of **+560.29/h** against 25/h, and a handle ceiling rise of **+33** against 16. Exit 2. Worth noting what did *not* catch it: the RSS ceiling rose 27.31 MB, under the 32 MB threshold. `phys_footprint` is the column carrying the memory signal, which is the whole argument for paying a second per sample to collect it |
| `stall-worker` | parks worker 0 forever mid-iteration, holding nothing | the progress counter, at 60 s: worker 0 stuck at iteration 59 while the other seven were at 856–1300. `findDeadlockedThreads` saw nothing, correctly — a `CountDownLatch` park is not a monitor cycle — which is the case the counter exists for. Exit 3 |
| `deadlock` | two workers take two monitors in opposite orders, through a barrier so the cycle is certain rather than lucky | `findDeadlockedThreads`, inside ten seconds, and the dump named it: `soak-worker-0 BLOCKED on java.lang.Object@5878515f owned by "soak-worker-1"` and the mirror image. Exit 3 |

All three were re-run after the criterion below changed, so those are the numbers the harness as
committed produces, not the ones that motivated the change.

Both stall paths also write `stall-native-sample.txt` — 348 KB and 404 KB of native frames from
macOS `sample` — because Java frames name the JNI entry point and stop there. A lock-order bug
in the shim looks like a thread sitting in `ChdbNative.streamAdvance` and nothing more; the
native stack is where `StreamHandle::mutex` waiting on `ConnHandle::mutex` would be visible.

**What the soak found, and why this row is still blocking.** One attempt at a long window did
not finish. It died between its 60-second and 75-second samples with `Bus error: 10` — exit 138
— and no `hs_err` file, no macOS `.ips` report and nothing in `/cores`.

**Attribution, carefully, because there are two candidates and that run cannot fully separate
them.** It was made with the *first* version of this harness, the one configured
`minimumIdle=0` — so it was in the engine-restart shape described above, and the
connection-count instrumentation that would have said whether the engine actually restarted did
not exist yet. So upstream allocator corruption cannot be excluded from that run.

What points at issue #14 rather than at allocator corruption is the signature. The crash was
SIGBUS and produced no crash report of any kind; allocator corruption is documented upstream as
an *abort*, which arrives as SIGABRT with the host handlers intact and therefore writes a report.
A missing report is #14's defining feature — HotSpot writes `hs_err` from the handler that the
opt-out removed. And `scripts/run-signal-window-test.sh measure` on the same build and engine
confirms that window is open, at 614–707 observations of a host handler at `SIG_DFL` per run.
The soak drives it harder than anything else here: a connection per query is around a hundred
`chdb_connect()` calls a second, each of which resets `SIGSEGV`, `SIGBUS` and six more to
`SIG_DFL` process-wide until the shim restores them.

So: **most likely #14, not provably only #14.** The table above is how a recurrence gets
classified in one step now, and the steady arm's zero-restart measurement is what makes that
classification possible.

If it is #14, the new part is not the mechanism, which
[findings §1a](upstream-findings.md) already documents. It is that **no synthetic signal
generator was involved.** §1a's lethal demonstration needed eight threads deliberately producing
stack-guard SIGSEGVs; this was an ordinary mixed workload, and ordinary JIT-compiled code
supplied the faults by itself. That would make the exposure "a pooled application that opens
connections at a normal rate can be killed silently, with no diagnostic" rather than "a stress
harness can provoke it".

Nothing in this repository closes it — the fix is an upstream API that sets the opt-out flag
without resetting the incumbent handlers — so **this is a release decision rather than a bug to
fix here**, and it is why the row above still says blocking. The options, none of them taken
yet:

- ship with it documented, since the driver already takes the lesser of two hazards and §1a
  explains why the alternative is three orders of magnitude worse;
- reduce the number of windows further by making connection churn rarer in the *documented*
  usage — a pool with `minimumIdle` equal to `maximumPoolSize` opens each connection once,
  which is a README recommendation rather than a code change;
- wait for upstream.

`scripts/run-soak-test.sh` now names the signature itself when a run dies this way, rather than
leaving an operator with exit 138 and no explanation.

### 3.2 Not blocking — worth doing, in this order

Ordered by what a first release would most regret missing.

| Gap | Why it matters | Effort |
|---|---|---|
| **Upload and download of a 98–166 MB artifact** | The one question on the consumption list that a `file://` repository cannot reach, because a copy cannot fail the way a transfer can. Comes free with running-order step 4. | free with the snapshot |
| **OpenJ9 / Semeru smoke test** | The signal-handler guard is written against HotSpot's behaviour and has never met another JVM. | half a day |
| **`noexec` /tmp** | The loader has a specific message for it that has never been executed. | an hour, in a container |
| **Corrupted library, architecture mismatch** | Named in the plan; the checksum path is tested, these two are not. | half a day |
| **JPMS module path** | `Automatic-Module-Name` is set; nothing has run on the module path. | half a day |
| **Spring `JdbcTemplate`** | HikariCP, MyBatis and jOOQ are done and each found something. This one is lower yield. | half a day |
| **ShardingSphere** | Not closable here: `StandardJdbcUrlParser` rejects every `jdbc:chdb:` form, so no config reaches the driver. Pinned by `ShardingSphereIT` so it flips when upstream fixes it. | upstream |
| **The §3.3 batch-access benchmark** | The plan requires three approaches measured before the data path is fixed. One was chosen by reasoning. | a day |
| **Full-process ASan and LSan** | Blocked on a sanitizer build of chdb-core. Not ours to close. | upstream |
| **Bit-identical shim builds** | Measured, and the answer is "no, by 116 bytes of build metadata" — `.github/workflows/release.yml`'s header has the breakdown. Nothing in the release gate depends on it. | not planned |

### What is already covered

266 tests — 156 unit and 110 integration, counted from a run rather than estimated — across
sixteen platform-and-JDK combinations, a 199-check native sanitizer harness, UBSan over the
whole suite, the full suite again on AlmaLinux 8 to demonstrate the glibc floor, and a consumer
that resolves the driver from a repository rather than from the reactor.

**The memory-limit gate is covered, and it is worth naming where** because it is not a JUnit
test and reading the test list alone would suggest otherwise. `scripts/run-memory-limit-test.sh`
runs a probe in an AlmaLinux 8 container under `docker --memory=2g`, with `-Xmx256m` and a
`groupArray` over 200 million values — so all three limits the work plan asks to be combined
(`-Xmx`, the cgroup limit and chDB's `max_memory_usage`) are in play at once. It runs both with
an explicit `max_memory_usage=200MB` and without one, and requires a catchable error code 241
in both; a completed query, a different error, or a process that dies without reporting are all
failures. `.github/workflows/build.yml` invokes it in the `oldest-supported-linux` job on both
`linux-x86_64-gnu` and `linux-aarch64-gnu`, unconditionally, on every push. (`docs/v1-progress.md`
phase 10 still lists a "cgroup + `max_memory_usage` matrix" as outstanding; that line is stale,
not a second opinion.)

The type matrix, parameter binding, streaming memory, cancellation, handle lifetime, the
storage-path rule, five loader failure paths, connection pooling — `HikariPoolIT`, a real
HikariCP 5.1.0 pool over the shared in-memory database — ClassLoader isolation and process exit
behaviour all have tests that were written to fail if the behaviour regressed, and several of
them found real defects when first run.

---

## The short answer

**Not ready. Most of the gating items are not code — but one of them now is.** Everything
mechanical is finished: the release profile, the signing, the licence inventory, the
four-platform assembly, and a local proof that the artifacts work when consumed from a
repository rather than from the reactor.

What is left is a DNS record on `chdb.org`, a decision about whose key signs, a licence answer
from whoever owns the engine, and two projects willing to depend on a snapshot. The
**Running order** at the top of this file is the sequence, because each of those can invalidate
the next; §3.1 is the part of Track 3 that blocks, and §3.2 is the part that does not.

The soak is no longer on that list in the same way. It is written, it has been run for 75
minutes, and it comes back clean on memory, handles and deadlocks — but it also killed the JVM
once, inside its first two minutes, with no crash report of any kind — most likely issue #14's
silent signal window, though that run predates the instrumentation that would have ruled out the
other candidate. Either way it is an engine-level hazard.
That is not a defect in this repository and cannot be fixed here, so it is not a task; it is a
**decision about what to ship and what to tell people**, and §3.1.1 lays out the three options.
Of everything on this page it is the one that changes what a user experiences rather than what a
maintainer has to do.
