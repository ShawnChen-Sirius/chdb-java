#!/usr/bin/env bash
#
# The concurrent soak of work plan section 5.11: several connections on several threads
# running a mixed workload for hours, with the memory trend recorded across it.
#
# Why this exists when two proxies already do half of it each. The 1000-query RSS plateau is
# long but sequential, so it measures the allocator and nothing else; HikariPoolIT is
# concurrent but runs for minutes. The milestone the gate discharges is that cancel, timeout,
# early close and cascading Connection close "leak nothing and never deadlock", and a deadlock
# cannot occur -- so cannot be ruled out -- in a single thread. Neither proxy can rule one out.
#
# It also exists because three mechanisms went into the concurrent path recently and none has
# been under load for longer than a test method: the ExecutionGate state word (-1 claimed by
# the shutdown hook / 0 idle / >0 threads inside a native statement start), the lock order
# StreamHandle::mutex -> ConnHandle::mutex -> HandleRegistry::mutex_, and the timeout execution
# number with its timeoutLock. All three are the kind of code that a short test passes and an
# hour of mixed load does not.
#
# What it measures, per sample:
#
#   rss                 ps -o rss=. Cheap enough to take every sample.
#   phys_footprint      The gate's "PSS" column. On Linux that is literally Pss, from
#                       /proc/<pid>/smaps_rollup. macOS has no PSS, so it is `footprint --pid`'s
#                       phys_footprint: the kernel's own ledger of what is charged to this task,
#                       which includes the compressor and excludes clean shared text.
#
#                       It is the honest number of the two. RSS counts pages of the 326 MB
#                       engine image as they are faulted in and does not count compressed pages,
#                       so RSS can fall while real usage grows -- and it did, in the calibration
#                       run: RSS stepped down 120 MB at two minutes while phys_footprint stayed
#                       flat. Costs about a second, so it is taken every other sample.
#   heap used           From the JVM, so a heap that grows can be told from native growth. The
#                       run is capped at -Xmx512m for the same reason: it bounds how much of
#                       the RSS slope the JVM can possibly account for.
#   native handles      ChdbNative.openHandleCount for all three kinds. This is the number to
#                       watch: NativeTestBase asserts it back to zero after every test, and a
#                       handle leak shows up here long before it is visible in RSS.
#   live threads        A driver that leaked a thread per statement would plateau in RSS and
#                       still be broken.
#
# What it asserts at the end. Everything is judged over the last 80% of the window, because the
# engine warms up in the first fifth -- it faults in its image, fills mark and uncompressed
# caches and settles -- and a statistic that includes warm-up measures warm-up.
#
# For memory the statistic is whether the *ceiling* rises: the highest value in the first half
# of that window against the highest in the second. Not a slope, which is what this asserted
# first and which failed a clean 75-minute run at +93 MB/h while RSS over the same window fell
# at 69 MB/h. phys_footprint here oscillates inside a 130 MB band with a period of about twenty
# minutes, so a least squares fit over a window of comparable length says whatever its endpoints
# want it to. SoakProbe.judgeMemory has the three-window demonstration and the numbers that
# separate a clean run from an injected leak. Slopes are still printed, as diagnostics.
#
# For handles the statistic is the slope, because a handle count is a small integer with no
# cache behind it to oscillate, plus a hard check that every handle is back to zero at the end.
#
# Deadlock detection is a progress counter per worker, not the total run timeout. A run that
# hangs and is killed by its own deadline tells you that it hung; it does not tell you where.
# Each worker bumps a counter per iteration, a watchdog thread checks every 10 seconds that
# every worker has moved within the stall window, and on a stall it dumps every Java thread
# (ThreadMXBean) plus every native frame (macOS `sample`) and exits non-zero. The watchdog also
# polls ThreadMXBean.findDeadlockedThreads, which reports a monitor cycle immediately -- but
# only a monitor cycle, so it would miss a StatementSlot semaphore or a std::mutex in the shim,
# and the progress counter is what covers those.
#
# Faults, for the only thing that makes a clean soak worth anything: proof that a dirty one
# goes red. --fault leak-resultset abandons one ResultSet every 40 iterations, which the handle
# slope and the memory ceiling have to catch; --fault stall-worker parks a worker forever, which
# only the progress watchdog can catch; --fault deadlock crosses two monitors between workers,
# which findDeadlockedThreads has to catch. All three are expected to fail the run.
#
# Not in per-PR CI. An hour-long job on every push would make the pipeline useless, so this is
# a manual and scheduled workflow (.github/workflows/soak.yml) and a script anyone can run.
#
# Usage:
#   scripts/run-soak-test.sh [--minutes N] [--threads N] [--sample-seconds N]
#                            [--stall-seconds N] [--fault none|leak-resultset|stall-worker|deadlock]
#                            [--arm steady|pool-drain]
#                            [--url JDBC-URL] [--out DIR] [--runtime DIR] [--jvm PATH]
#                            [--max-ceiling-rise MB] [--max-handle-slope N/h]
#                            [--max-handle-ceiling-rise N]
#   scripts/run-soak-test.sh --analyze <dir-or-samples.csv>
#
# Leaves samples.csv, verdict.txt, run.properties, soak.log and, on a stall, stall-report.txt
# in the output directory. samples.csv is a plain time series with a header, flushed every
# sample, so a run that is killed still leaves everything it measured -- and --analyze re-judges
# a recorded one against today's thresholds without running anything, which is what makes an
# uploaded CI artifact worth keeping.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
die() { printf 'run-soak-test: %s\n' "$*" >&2; exit 1; }

MINUTES=60
THREADS=8
SAMPLE_SECONDS=15
STALL_SECONDS=180
FAULT=none
ARM=steady
URL="jdbc:chdb::memory:"
OUT=""
RUNTIME=""
JVM=""
XMX=512m
MAX_CEILING_RISE=32
MAX_HANDLE_SLOPE=25
MAX_HANDLE_CEILING_RISE=16
ANALYZE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) MINUTES="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --sample-seconds) SAMPLE_SECONDS="$2"; shift 2 ;;
    --stall-seconds) STALL_SECONDS="$2"; shift 2 ;;
    --fault) FAULT="$2"; shift 2 ;;
    --arm) ARM="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --jvm) JVM="$2"; shift 2 ;;
    --xmx) XMX="$2"; shift 2 ;;
    --max-ceiling-rise) MAX_CEILING_RISE="$2"; shift 2 ;;
    --max-handle-slope) MAX_HANDLE_SLOPE="$2"; shift 2 ;;
    --max-handle-ceiling-rise) MAX_HANDLE_CEILING_RISE="$2"; shift 2 ;;
    --analyze) ANALYZE="$2"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (try --help)" ;;
  esac
done

case "$FAULT" in
  none|leak-resultset|stall-worker|deadlock) ;;
  *) die "unknown --fault $FAULT" ;;
esac

case "$ARM" in
  steady|pool-drain) ;;
  *) die "unknown --arm $ARM (steady or pool-drain)" ;;
esac

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  DEFAULT_PLATFORM=macos-aarch64;        DEFAULT_DIR="macos/aarch64" ;;
  Darwin-x86_64) DEFAULT_PLATFORM=macos-x86_64;         DEFAULT_DIR="macos/x86_64" ;;
  Linux-aarch64) DEFAULT_PLATFORM=linux-aarch64-gnu;    DEFAULT_DIR="linux/aarch64" ;;
  Linux-x86_64)  DEFAULT_PLATFORM=linux-x86_64-gnu;     DEFAULT_DIR="linux/x86_64" ;;
  *) die "unsupported host $(uname -s)-$(uname -m)" ;;
esac

if [ -z "$RUNTIME" ]; then
  RUNTIME="${ROOT}/chdb-native-${DEFAULT_PLATFORM}/target/native/META-INF/chdb/native/${DEFAULT_DIR}"
fi

JAVA_BIN="${JVM:-${JAVA_HOME:+${JAVA_HOME}/bin/}java}"
JAVAC_BIN="${JAVA_HOME:+${JAVA_HOME}/bin/}javac"

PROBE="${ROOT}/target/soak-probe"
mkdir -p "$PROBE"

cat > "${PROBE}/SoakProbe.java" <<'JAVA'
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.lang.management.ManagementFactory;
import java.lang.management.ThreadInfo;
import java.lang.management.ThreadMXBean;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.SQLTimeoutException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.BrokenBarrierException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;
import org.chdb.internal.ChdbNative;

/**
 * A mixed concurrent workload against one chDB storage path, sampled while it runs.
 *
 * <p>The shape is HikariPoolIT's, scaled up in time: a pool, several threads, and a connection
 * per query rather than per thread, because a connection per query is what churns the storage
 * path registry and the per-connection statement slot hardest. A quarter of the iterations
 * bypass the pool and go to DriverManager instead, so the registry's acquire and release are
 * exercised outside the pool's own idle bookkeeping -- and so that the driver's cascading
 * close can be tested at all, which through a pool it cannot: HikariCP closes the tracked
 * Statements itself on return, so a pooled Connection.close() never reaches the driver's own
 * cascade.
 */
public final class SoakProbe {

    // ---------------------------------------------------------------- configuration

    private static long durationMillis;
    private static int threads;
    private static long sampleMillis;
    private static long stallMillis;
    /** Take phys_footprint every other sample: it costs about a second, RSS costs nothing. */
    private static int footprintEvery = 2;
    private static String fault = "none";
    private static String arm = "steady";
    private static String url = "jdbc:chdb::memory:";
    private static Path out;
    private static double maxCeilingRiseMb;
    private static double maxHandleSlopePerHour;
    private static double maxHandleCeilingRise;

    /** Refuse to call a run clean on too little evidence. See {@link #verdict}. */
    private static final int MIN_SAMPLES = 12;
    private static final long MIN_ITERATIONS = 200;

    /**
     * How many unexpected failures a clean run may have. Zero.
     *
     * <p>Every shape in the mix either succeeds or fails in a way the shape itself expects --
     * a cancel that was cancelled, a timeout that timed out, an unknown column rejected with
     * code 47. Nothing else is a legitimate outcome, so a rate allowance would only be a way
     * to average away the finding. A failing iteration does not stop the run either: it is
     * counted, its stack is kept, and the window finishes, so zero costs nothing.
     */
    private static final long MAX_UNEXPECTED = 0;

    // ---------------------------------------------------------------- state

    private static volatile boolean running = true;
    private static volatile String stallReport;

    private static AtomicLong[] progress;
    private static final AtomicLong iterations = new AtomicLong();
    private static final AtomicLong rowsRead = new AtomicLong();
    private static final AtomicLong unexpected = new AtomicLong();

    /**
     * How often this process had no chDB connection open at all, and so no engine.
     *
     * <p>Not curiosity, and the reason the {@code steady} arm pins a connection. chdb-core's own
     * test runner records that "starting and tearing the embedded engine down on every
     * connection repeatedly can corrupt the process allocator and abort under load on macOS",
     * and works around it by splitting its suite across processes "so that no single process
     * accumulates the whole suite's engine create/destroy churn". The engine is booted by the
     * connection that finds none open and torn down by the last one to close — the driver's own
     * documentation says the {@code :memory:} database "lives until the last of them closes" —
     * so a soak that repeatedly drains to zero connections is sitting squarely in that
     * known-dangerous shape, and a crash it produced would be that known upstream issue rather
     * than a finding about this driver.
     *
     * <p>Measured, not assumed. The 15-second sampler cannot answer it: a gap between iterations
     * is milliseconds wide. So a dedicated thread polls the live connection-handle count every
     * 5 ms, counts the times it saw zero, and counts the transitions from zero back up — which
     * is the number of times the engine booted. In the {@code steady} arm both must be zero
     * after the pin is taken, and the verdict fails if they are not: "we were measuring our own
     * driver" is a claim that needs evidence, not a configuration comment.
     */
    private static final AtomicLong zeroConnectionObservations = new AtomicLong();
    private static final AtomicLong engineFloorSamples = new AtomicLong();
    private static final AtomicLong engineBoots = new AtomicLong();
    private static volatile long minConnectionHandles = Long.MAX_VALUE;

    /** The connection held open for the whole window in the {@code steady} arm. */
    private static Connection pinnedConnection;

    /**
     * Set while the {@code pool-drain} arm is deliberately idle, so the pool can empty.
     *
     * <p>Without it the arm would not drain anything: eight workers under continuous load keep
     * the pool busy, and HikariCP only evicts what has been idle. A low-traffic service — the
     * kind that gets configured with {@code minimumIdle=0} in the first place — has quiet
     * windows by definition, so the arm reproduces them: ten seconds of load, five seconds of
     * quiet, repeatedly, against a one-second idle timeout.
     */
    private static volatile boolean quiet;

    /** Per shape and per outcome, so the report can say what actually ran rather than what was asked for. */
    private static final Map<String, AtomicLong> outcomes =
            Collections.synchronizedMap(new LinkedHashMap<String, AtomicLong>());

    /** The first few unexpected failures, verbatim. A count alone cannot be diagnosed. */
    private static final List<String> firstErrors = Collections.synchronizedList(new ArrayList<String>());

    /** Deliberately abandoned result sets, held so nothing can collect them. Only in --fault leak-resultset. */
    private static final List<Object> leaked = Collections.synchronizedList(new ArrayList<Object>());

    private static final Object LOCK_A = new Object();
    private static final Object LOCK_B = new Object();
    private static final CyclicBarrier DEADLOCK_RENDEZVOUS = new CyclicBarrier(2);

    private static final List<Sample> samples = Collections.synchronizedList(new ArrayList<Sample>());

    private static ScheduledExecutorService cancellers;
    private static HikariDataSource pool;

    private static final class Sample {
        long elapsedSeconds;
        long rss;
        long footprint;      // -1 when not sampled in this tick
        long heapUsed;
        long handlesConnection;
        long handlesResult;
        long handlesStream;
        int liveThreads;
        long iterations;

        long handlesTotal() {
            return handlesConnection + handlesResult + handlesStream;
        }
    }

    // ---------------------------------------------------------------- the workload

    /**
     * The mix, with the weights it is drawn with.
     *
     * <p>Weighted rather than uniform because the shapes cost between a millisecond and several
     * seconds, and a uniform draw would spend the whole window on the expensive ones. What the
     * gate needs is many iterations of the lifecycle-churning shapes -- a leak of a hundred
     * bytes an iteration is only visible at a hundred thousand iterations -- plus enough of the
     * cancel and timeout shapes to have actually tried them. Every shape is asserted to have
     * run at least once before the run can be called clean.
     */
    private static final String[] SHAPES = {
        "stream-full",        // a streaming SELECT read to exhaustion, batch by batch
        "stream-early-close", // close() on a result set with millions of rows left
        "cascade-close",      // close the Connection with an open Statement and ResultSet under it
        "materialized",       // SHOW / DESCRIBE / EXPLAIN: the chdb_query_arrow_n route
        "prepared",           // PreparedStatement with parameters
        "ddl-dml",            // CREATE / INSERT / SELECT / TRUNCATE: the no-result-set route
        "error",              // a statement the engine rejects, to check the failure path frees handles
        "metadata",           // DatabaseMetaData, which runs its own queries and result sets
        "cancel",             // Statement.cancel() from another thread, mid-fetch
        "timeout-stream",     // setQueryTimeout expiring during next()
        "timeout-open",       // setQueryTimeout expiring inside the uninterruptible open
    };
    private static final int[] WEIGHTS = {22, 14, 14, 18, 10, 6, 6, 1, 5, 2, 2};

    private static String pickShape(Random random) {
        int total = 0;
        for (int weight : WEIGHTS) {
            total += weight;
        }
        int draw = random.nextInt(total);
        for (int i = 0; i < SHAPES.length; i++) {
            draw -= WEIGHTS[i];
            if (draw < 0) {
                return SHAPES[i];
            }
        }
        return SHAPES[0];
    }

    private static void count(String key) {
        AtomicLong counter = outcomes.get(key);
        if (counter == null) {
            synchronized (outcomes) {
                counter = outcomes.get(key);
                if (counter == null) {
                    counter = new AtomicLong();
                    outcomes.put(key, counter);
                }
            }
        }
        counter.incrementAndGet();
    }

    /** A connection from the pool, or straight from the driver a quarter of the time. */
    private static Connection connect(Random random) throws SQLException {
        return random.nextInt(4) == 0 ? DriverManager.getConnection(url) : pool.getConnection();
    }

    private static void runShape(String shape, int worker, Random random, long iteration)
            throws SQLException, InterruptedException {
        switch (shape) {
            case "stream-full": {
                if ("leak-resultset".equals(fault) && worker == 0 && iteration % 40 == 0) {
                    // Held open on purpose, including the Connection, so nothing cascades it
                    // shut. One connection handle and one stream handle per occurrence, which
                    // is what the handle slope has to see.
                    Connection connection = DriverManager.getConnection(url);
                    Statement statement = connection.createStatement();
                    ResultSet rs = statement.executeQuery("SELECT number FROM numbers(1000000)");
                    rs.next();
                    leaked.add(new Object[] {connection, statement, rs});
                    count("fault:leaked-a-result-set");
                    return;
                }
                long wanted = 20000 + random.nextInt(180000);
                long rows = 0;
                long checksum = 0;
                try (Connection connection = connect(random);
                        Statement statement = connection.createStatement();
                        ResultSet rs =
                                statement.executeQuery(
                                        "SELECT number, toString(number) AS t, number % 7 AS m"
                                                + " FROM numbers(" + wanted + ")")) {
                    while (rs.next()) {
                        rows++;
                        checksum += rs.getLong(1) + rs.getString(2).length() + rs.getInt(3);
                    }
                }
                if (rows != wanted) {
                    throw new IllegalStateException("stream-full read " + rows + " of " + wanted);
                }
                if (checksum == Long.MIN_VALUE) {
                    throw new IllegalStateException("unreachable, and keeps the read observable");
                }
                rowsRead.addAndGet(rows);
                count("stream-full:ok");
                break;
            }

            case "stream-early-close": {
                // A hundred million rows requested and five hundred read. Sized from measurement
                // rather than by feel: read to exhaustion this query takes about 0.8 s, so the
                // engine is certainly still producing when close() arrives, which is the case
                // that has to release the stream handle rather than wait for it to drain.
                long rows = 0;
                try (Connection connection = connect(random);
                        Statement statement = connection.createStatement();
                        ResultSet rs =
                                statement.executeQuery(
                                        "SELECT number, sipHash64(toString(number)) AS h"
                                                + " FROM numbers(100000000)")) {
                    while (rows < 500 && rs.next()) {
                        rows++;
                    }
                }
                rowsRead.addAndGet(rows);
                count("stream-early-close:ok");
                break;
            }

            case "cascade-close": {
                // DriverManager, not the pool: HikariCP closes its tracked Statements on return,
                // so a pooled connection never exercises the driver's own cascade.
                Connection connection = DriverManager.getConnection(url);
                Statement statement = connection.createStatement();
                ResultSet rs =
                        statement.executeQuery(
                                "SELECT number, sipHash64(toString(number)) AS h FROM numbers(100000000)");
                long rows = 0;
                while (rows < 50 && rs.next()) {
                    rows++;
                }
                connection.close();
                if (!rs.isClosed()) {
                    throw new IllegalStateException("Connection.close() left the ResultSet open");
                }
                if (!statement.isClosed()) {
                    throw new IllegalStateException("Connection.close() left the Statement open");
                }
                rowsRead.addAndGet(rows);
                count("cascade-close:ok");
                break;
            }

            case "materialized": {
                // The chdb_query_arrow_n route. Every one of these was measured refusing the
                // streaming door on the pinned engine (issue #12), so this is the only shape in
                // the mix that goes through streamOpenMaterialized.
                String[] queries = {
                    "SHOW TABLES",
                    "SHOW DATABASES",
                    "DESCRIBE TABLE numbers(1)",
                    "EXPLAIN SELECT number FROM numbers(10) WHERE number > 3",
                    "EXISTS TABLE system.one",
                    "SHOW SETTINGS LIKE 'max_thread%'",
                };
                String sql = queries[random.nextInt(queries.length)];
                long rows = 0;
                try (Connection connection = connect(random);
                        Statement statement = connection.createStatement();
                        ResultSet rs = statement.executeQuery(sql)) {
                    ResultSetMetaData meta = rs.getMetaData();
                    int columns = meta.getColumnCount();
                    while (rs.next()) {
                        rows++;
                        for (int c = 1; c <= columns; c++) {
                            rs.getString(c);
                        }
                    }
                }
                rowsRead.addAndGet(rows);
                count("materialized:ok");
                break;
            }

            case "prepared": {
                // toUInt64 around the numeric parameters is not decoration. Every bound
                // parameter travels as a server-side {pN:String} and ClickHouse will not
                // implicitly convert one to a numeric argument -- docs/unsupported.md
                // "A bound parameter is a String" -- so numbers(?) is refused with code 43 and
                // numbers(toUInt64(?)) is the documented form. Written the documented way on
                // purpose: a soak that used the refused form would spend the window measuring
                // the error path instead of the parameter path.
                long rows = 0;
                try (Connection connection = connect(random);
                        PreparedStatement ps =
                                connection.prepareStatement(
                                        "SELECT number, ? AS tag FROM numbers(toUInt64(?))"
                                                + " WHERE number % toUInt64(?) = toUInt64(?)")) {
                    ps.setString(1, "worker-" + worker + "-o'brien");
                    ps.setInt(2, 20000 + random.nextInt(60000));
                    ps.setInt(3, 3);
                    ps.setInt(4, 1);
                    try (ResultSet rs = ps.executeQuery()) {
                        while (rs.next()) {
                            rows++;
                            rs.getLong(1);
                            rs.getString(2);
                        }
                    }
                }
                rowsRead.addAndGet(rows);
                count("prepared:ok");
                break;
            }

            case "ddl-dml": {
                // Per worker, because :memory: is one database shared by every connection in
                // the process and two workers dropping the same table would race.
                String table = "soak_w" + worker;
                try (Connection connection = connect(random);
                        Statement statement = connection.createStatement()) {
                    statement.execute(
                            "CREATE TABLE IF NOT EXISTS " + table
                                    + " (id UInt64, s String) ENGINE = Memory");
                    statement.executeUpdate(
                            "INSERT INTO " + table
                                    + " SELECT number, toString(number) FROM numbers(2000)");
                    try (ResultSet rs =
                            statement.executeQuery("SELECT count(), sum(id) FROM " + table)) {
                        if (!rs.next()) {
                            throw new IllegalStateException("count() returned no row");
                        }
                        if (rs.getLong(1) < 2000) {
                            throw new IllegalStateException("insert lost rows: " + rs.getLong(1));
                        }
                    }
                    statement.execute("TRUNCATE TABLE " + table);
                }
                count("ddl-dml:ok");
                break;
            }

            case "error": {
                try (Connection connection = connect(random);
                        Statement statement = connection.createStatement()) {
                    try (ResultSet rs = statement.executeQuery("SELECT no_such_column_in_soak")) {
                        rs.next();
                        throw new IllegalStateException("the engine accepted an unknown column");
                    } catch (SQLException expected) {
                        if (expected.getErrorCode() != 47) {
                            throw new IllegalStateException(
                                    "expected UNKNOWN_IDENTIFIER (47), got "
                                            + expected.getErrorCode() + ": "
                                            + expected.getMessage());
                        }
                    }
                    // And the connection still works, which is what makes a pool keep it.
                    try (ResultSet rs = statement.executeQuery("SELECT 1")) {
                        if (!rs.next()) {
                            throw new IllegalStateException("the connection died with the error");
                        }
                    }
                }
                count("error:rejected-with-code-47");
                break;
            }

            case "metadata": {
                try (Connection connection = connect(random)) {
                    DatabaseMetaData metaData = connection.getMetaData();
                    try (ResultSet rs = metaData.getTables(null, "system", "one", null)) {
                        while (rs.next()) {
                            rs.getString("TABLE_NAME");
                        }
                    }
                    try (ResultSet rs = metaData.getColumns(null, "system", "one", "%")) {
                        while (rs.next()) {
                            rs.getString("COLUMN_NAME");
                        }
                    }
                    if (metaData.getDatabaseProductVersion() == null) {
                        throw new IllegalStateException("no product version");
                    }
                }
                count("metadata:ok");
                break;
            }

            case "cancel": {
                // From another thread while this one is inside next(), which is the only
                // concurrent call ChdbStatement documents as legal.
                try (Connection connection = connect(random)) {
                    final Statement statement = connection.createStatement();
                    ScheduledFuture<?> scheduled =
                            cancellers.schedule(
                                    () -> {
                                        try {
                                            statement.cancel();
                                        } catch (SQLException ignored) {
                                            // Racing a statement that already finished is the
                                            // point of the shape, not a failure of it.
                                        }
                                    },
                                    40 + random.nextInt(200),
                                    TimeUnit.MILLISECONDS);
                    try {
                        long rows = 0;
                        try (ResultSet rs =
                                statement.executeQuery(
                                        "SELECT number, sipHash64(toString(number)) AS h"
                                                + " FROM numbers(200000000)")) {
                            while (rs.next()) {
                                rows++;
                            }
                        }
                        rowsRead.addAndGet(rows);
                        count("cancel:query-finished-first");
                    } catch (SQLException e) {
                        String message = e.getMessage() == null ? "" : e.getMessage();
                        if (message.toLowerCase(Locale.ROOT).contains("cancel")) {
                            count("cancel:cancelled");
                        } else {
                            throw e;
                        }
                    } finally {
                        scheduled.cancel(false);
                        statement.close();
                    }
                }
                break;
            }

            case "timeout-stream": {
                // Two hundred million rows of sipHash64 at a one second budget: the open returns
                // quickly because a plain SELECT emits as it scans, so the deadline lands in
                // next() and the timeout has a stream handle to cancel. Two hundred million
                // because twenty million was measured taking 0.15 s end to end on this host --
                // a size chosen by feel would have made this shape a no-op that never once
                // reached the timeout it exists to test, which is what the first draft did.
                try (Connection connection = connect(random);
                        Statement statement = connection.createStatement()) {
                    statement.setQueryTimeout(1);
                    try (ResultSet rs =
                            statement.executeQuery(
                                    "SELECT number, sipHash64(toString(number)) AS h"
                                            + " FROM numbers(200000000)")) {
                        while (rs.next()) {
                            rs.getLong(1);
                        }
                        count("timeout-stream:finished-inside-the-budget");
                    } catch (SQLTimeoutException expected) {
                        count("timeout-stream:timed-out");
                    }
                }
                break;
            }

            case "timeout-open": {
                // A full aggregate at a one second budget. Nothing can be cancelled while the
                // open is in flight -- every cancel the C ABI exports takes the handle the open
                // is still producing -- so this is the deadline check after the open returns.
                try (Connection connection = connect(random);
                        Statement statement = connection.createStatement()) {
                    statement.setQueryTimeout(1);
                    try (ResultSet rs =
                            statement.executeQuery(
                                    "SELECT sum(sipHash64(toString(number))) FROM numbers(200000000)")) {
                        rs.next();
                        count("timeout-open:finished-inside-the-budget");
                    } catch (SQLTimeoutException expected) {
                        count("timeout-open:timed-out");
                    }
                }
                break;
            }

            default:
                throw new IllegalStateException("unknown shape " + shape);
        }
    }

    // ---------------------------------------------------------------- workers

    private static void worker(int index, long deadline) {
        Random random = new Random(ThreadLocalRandom.current().nextLong() ^ index);
        long iteration = 0;
        while (running && System.currentTimeMillis() < deadline) {
            if (quiet) {
                // The pool-drain arm is idle on purpose. Sleeping here rather than skipping the
                // iteration keeps the progress counter still, which is correct: the watchdog
                // only ever runs against the steady arm.
                try {
                    Thread.sleep(200);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
                continue;
            }
            iteration++;
            String shape = pickShape(random);
            try {
                injectFault(index, iteration);
                runShape(shape, index, random, iteration);
            } catch (Throwable t) {
                unexpected.incrementAndGet();
                count("UNEXPECTED:" + shape + ":" + t.getClass().getSimpleName());
                synchronized (firstErrors) {
                    if (firstErrors.size() < 20) {
                        firstErrors.add(
                                "worker " + index + " shape " + shape + ": " + t + describe(t));
                    }
                }
            } finally {
                // After the shape, so a worker parked inside one stops reporting progress --
                // which is exactly what the watchdog is looking for.
                progress[index].incrementAndGet();
                iterations.incrementAndGet();
            }
        }
    }

    private static String describe(Throwable t) {
        StackTraceElement[] frames = t.getStackTrace();
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < Math.min(6, frames.length); i++) {
            text.append("\n      at ").append(frames[i]);
        }
        return text.toString();
    }

    /** The three ways this harness is asked to prove it is not empty. */
    private static void injectFault(int worker, long iteration) throws InterruptedException {
        if ("stall-worker".equals(fault) && worker == 0 && iteration == 60) {
            // Parked with nothing held, which is the harder case: no monitor cycle for
            // findDeadlockedThreads to see, so only the progress counter can catch it.
            count("fault:parked-worker-0");
            System.out.println("[fault] worker 0 is parking for good at iteration 60");
            new CountDownLatch(1).await();
        }
        if ("deadlock".equals(fault) && (worker == 0 || worker == 1) && iteration == 60) {
            if (threads < 2) {
                throw new IllegalStateException("--fault deadlock needs at least two workers");
            }
            Object first = worker == 0 ? LOCK_A : LOCK_B;
            Object second = worker == 0 ? LOCK_B : LOCK_A;
            count("fault:crossed-monitors-worker-" + worker);
            System.out.println("[fault] worker " + worker + " is crossing two monitors");
            synchronized (first) {
                // A rendezvous rather than a sleep, and it is taken while each worker already
                // holds its own monitor. A sleep would leave the cycle to luck: the two workers
                // do not reach iteration 60 at the same moment, so one could take both monitors
                // and release them before the other arrived, and the fault run would then pass
                // -- reporting the harness broken when it is the fault that failed to happen.
                try {
                    DEADLOCK_RENDEZVOUS.await(60, TimeUnit.SECONDS);
                } catch (BrokenBarrierException | TimeoutException e) {
                    throw new IllegalStateException("the deadlock rendezvous failed", e);
                }
                synchronized (second) {
                    System.out.println("[fault] no cycle formed, which is itself a problem");
                }
            }
        }
    }

    // ---------------------------------------------------------------- sampling

    private static long rssBytes() {
        String value = shell("/bin/ps", "-o", "rss=", "-p", String.valueOf(pid()));
        if (value == null) {
            return -1;
        }
        try {
            return Long.parseLong(value.trim()) * 1024L;
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /**
     * The macOS phys_footprint, in bytes, or -1 where there is no such tool.
     *
     * <p>On Linux the same column is filled from smaps_rollup's Pss, which is the number this
     * gate is actually named after. On macOS phys_footprint is the closest thing that exists:
     * the kernel's own ledger of pages charged to the task, counting the compressor and not
     * counting clean shared text.
     */
    private static long footprintBytes() {
        Path rollup = Paths.get("/proc/" + pid() + "/smaps_rollup");
        if (Files.isReadable(rollup)) {
            try {
                for (String line : Files.readAllLines(rollup, StandardCharsets.UTF_8)) {
                    if (line.startsWith("Pss:")) {
                        String[] parts = line.trim().split("\\s+");
                        return Long.parseLong(parts[1]) * 1024L;
                    }
                }
            } catch (IOException | RuntimeException e) {
                return -1;
            }
            return -1;
        }
        String text = shell("/usr/bin/footprint", "--pid", String.valueOf(pid()), "-f", "bytes");
        if (text == null) {
            return -1;
        }
        for (String line : text.split("\n")) {
            String trimmed = line.trim();
            if (trimmed.startsWith("phys_footprint:")) {
                String digits = trimmed.replaceAll("[^0-9]", "");
                if (!digits.isEmpty()) {
                    return Long.parseLong(digits);
                }
            }
        }
        return -1;
    }

    private static long pid() {
        return ProcessHandle.current().pid();
    }

    private static String shell(String... command) {
        try {
            ProcessBuilder builder = new ProcessBuilder(command);
            builder.redirectErrorStream(true);
            Process process = builder.start();
            StringBuilder text = new StringBuilder();
            try (BufferedReader reader =
                    new BufferedReader(
                            new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    text.append(line).append('\n');
                }
            }
            if (!process.waitFor(30, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                return null;
            }
            return process.exitValue() == 0 ? text.toString() : null;
        } catch (IOException | InterruptedException e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            return null;
        }
    }

    private static void sampler(long start, long deadline) {
        Path csv = out.resolve("samples.csv");
        int tick = 0;
        try (PrintWriter writer =
                new PrintWriter(
                        Files.newBufferedWriter(
                                csv,
                                StandardCharsets.UTF_8,
                                StandardOpenOption.CREATE,
                                StandardOpenOption.TRUNCATE_EXISTING))) {
            writer.println(
                    "elapsed_s,rss_bytes,phys_footprint_bytes,heap_used_bytes,"
                            + "handles_connection,handles_result,handles_stream,live_threads,iterations");
            writer.flush();
            while (running && System.currentTimeMillis() < deadline + sampleMillis) {
                Sample sample = new Sample();
                sample.elapsedSeconds = (System.currentTimeMillis() - start) / 1000L;
                sample.rss = rssBytes();
                // Every other tick by default: footprint takes about a second, and taking it
                // every tick would put a second of forked work into every sampling interval.
                sample.footprint = (tick % footprintEvery == 0) ? footprintBytes() : -1;
                sample.heapUsed = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getUsed();
                sample.handlesConnection = ChdbNative.openHandleCount(ChdbNative.KIND_CONNECTION);
                sample.handlesResult = ChdbNative.openHandleCount(ChdbNative.KIND_RESULT);
                sample.handlesStream = ChdbNative.openHandleCount(ChdbNative.KIND_STREAM);
                sample.liveThreads = ManagementFactory.getThreadMXBean().getThreadCount();
                sample.iterations = iterations.get();
                samples.add(sample);
                writer.println(
                        sample.elapsedSeconds + "," + sample.rss + "," + sample.footprint + ","
                                + sample.heapUsed + "," + sample.handlesConnection + ","
                                + sample.handlesResult + "," + sample.handlesStream + ","
                                + sample.liveThreads + "," + sample.iterations);
                // Flushed every sample so a run that is killed still leaves its series behind.
                writer.flush();
                if (tick % 8 == 0) {
                    System.out.printf(
                            Locale.ROOT,
                            "[%6ds] rss=%6.1fMB footprint=%s heap=%5.1fMB handles=%d/%d/%d"
                                    + " threads=%d iterations=%d errors=%d%n",
                            sample.elapsedSeconds,
                            sample.rss / 1048576.0,
                            sample.footprint < 0
                                    ? "-"
                                    : String.format(Locale.ROOT, "%.1fMB", sample.footprint / 1048576.0),
                            sample.heapUsed / 1048576.0,
                            sample.handlesConnection,
                            sample.handlesResult,
                            sample.handlesStream,
                            sample.liveThreads,
                            sample.iterations,
                            unexpected.get());
                }
                tick++;
                Thread.sleep(sampleMillis);
            }
        } catch (IOException e) {
            System.out.println("sampler failed: " + e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /**
     * Watches for the moment this process has no engine, at 5 ms resolution.
     *
     * <p>See {@link #zeroConnectionObservations} for why this is worth a thread.
     */
    private static void engineFloorWatcher(long deadline) {
        boolean wasZero = false;
        while (running && System.currentTimeMillis() < deadline) {
            long open = ChdbNative.openHandleCount(ChdbNative.KIND_CONNECTION);
            engineFloorSamples.incrementAndGet();
            if (open == 0) {
                zeroConnectionObservations.incrementAndGet();
                wasZero = true;
            } else if (wasZero) {
                // Zero, then not zero: a connection found no engine and booted one.
                engineBoots.incrementAndGet();
                wasZero = false;
            }
            if (open < minConnectionHandles) {
                minConnectionHandles = open;
            }
            try {
                Thread.sleep(5);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    /** Cycles the {@code pool-drain} arm between load and quiet so the pool can empty. */
    private static void quietCycler(long deadline) {
        try {
            while (running && System.currentTimeMillis() < deadline) {
                quiet = false;
                Thread.sleep(10000);
                if (!running) {
                    return;
                }
                quiet = true;
                Thread.sleep(5000);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            quiet = false;
        }
    }

    // ---------------------------------------------------------------- the watchdog

    /**
     * Checks that every worker is still moving, and says where it stopped if one is not.
     *
     * <p>A total run timeout would tell you the run hung. This tells you which thread stopped
     * and what it was in, which for a lock-order bug in the shim is the whole answer.
     */
    private static void watchdog(long deadline) {
        long[] lastSeen = new long[threads];
        long[] lastMoved = new long[threads];
        long now = System.currentTimeMillis();
        Arrays.fill(lastMoved, now);
        ThreadMXBean threadBean = ManagementFactory.getThreadMXBean();

        while (running && System.currentTimeMillis() < deadline) {
            try {
                Thread.sleep(10000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
            now = System.currentTimeMillis();

            long[] deadlocked = threadBean.findDeadlockedThreads();
            if (deadlocked != null && deadlocked.length > 0) {
                // Only ever a monitor or an owned Lock cycle. A StatementSlot semaphore or a
                // std::mutex in the shim is invisible here, which is why the progress check
                // below exists as well.
                report("JMX reported a deadlock cycle among " + deadlocked.length + " threads");
                return;
            }

            for (int i = 0; i < threads; i++) {
                long current = progress[i].get();
                if (current != lastSeen[i]) {
                    lastSeen[i] = current;
                    lastMoved[i] = now;
                } else if (now - lastMoved[i] > stallMillis) {
                    report(
                            "worker " + i + " has not completed an iteration in "
                                    + ((now - lastMoved[i]) / 1000) + "s (stall window "
                                    + (stallMillis / 1000) + "s); it is at iteration " + current);
                    return;
                }
            }
        }
    }

    private static void report(String why) {
        running = false;
        StringBuilder text = new StringBuilder();
        text.append("SOAK STALLED: ").append(why).append("\n\n");
        text.append("progress per worker:\n");
        for (int i = 0; i < threads; i++) {
            text.append("  worker ").append(i).append(": ").append(progress[i].get()).append('\n');
        }
        text.append("\nlive handles: connection=")
                .append(ChdbNative.openHandleCount(ChdbNative.KIND_CONNECTION))
                .append(" result=").append(ChdbNative.openHandleCount(ChdbNative.KIND_RESULT))
                .append(" stream=").append(ChdbNative.openHandleCount(ChdbNative.KIND_STREAM))
                .append("\n\n=== Java threads (ThreadMXBean.dumpAllThreads) ===\n");
        ThreadMXBean threadBean = ManagementFactory.getThreadMXBean();
        for (ThreadInfo info : threadBean.dumpAllThreads(true, true)) {
            text.append('"').append(info.getThreadName()).append("\" #").append(info.getThreadId())
                    .append(' ').append(info.getThreadState());
            if (info.getLockName() != null) {
                text.append(" on ").append(info.getLockName());
            }
            if (info.getLockOwnerName() != null) {
                text.append(" owned by \"").append(info.getLockOwnerName()).append('"');
            }
            text.append('\n');
            for (StackTraceElement frame : info.getStackTrace()) {
                text.append("\tat ").append(frame).append('\n');
            }
            text.append('\n');
        }

        // Java frames name the JNI entry point and stop there. A lock-order bug in the shim is
        // below that line -- StreamHandle::mutex waiting on ConnHandle::mutex looks like a
        // thread sitting in `ChdbNative.streamAdvance` and nothing more -- so take the native
        // stacks too where the platform has a tool for them. macOS has `sample`; on Linux this
        // needs elfutils and usually finds nothing, which is said rather than left blank.
        text.append("=== native stacks ===\n");
        Path nativeDump = out.resolve("stall-native-sample.txt");
        String stacks = null;
        if (shell("/usr/bin/sample", String.valueOf(pid()), "3", "-mayDie",
                        "-f", nativeDump.toString()) != null) {
            try {
                stacks = new String(Files.readAllBytes(nativeDump), StandardCharsets.UTF_8);
            } catch (IOException e) {
                stacks = "sample ran but its output could not be read: " + e;
            }
        }
        if (stacks == null) {
            stacks = shell("/usr/bin/eu-stack", "-p", String.valueOf(pid()));
        }
        text.append(stacks == null ? "(no native stack tool on this platform)\n" : stacks);

        String dump = text.toString();
        System.out.println(dump);
        try {
            Files.write(out.resolve("stall-report.txt"), dump.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            System.out.println("could not write the stall report: " + e);
        }
        stallReport = why;
    }

    // ---------------------------------------------------------------- regression and verdict

    private static final class Fit {
        int points;
        double slopePerHour;
        double first;
        double last;
        double min;
        double max;

        /** Highest value in the first half of the fit window, and in the second. */
        double ceilingFirstHalf;
        double ceilingSecondHalf;

        double ceilingRise() {
            return ceilingSecondHalf - ceilingFirstHalf;
        }
    }

    /**
     * Least squares over the last 80% of the window.
     *
     * <p>The first fifth is dropped rather than fitted because the engine warms up in it -- it
     * faults in its image, fills its caches and settles -- and a fit that includes warm-up
     * measures the warm-up. Twelve minutes of an hour, which is comfortably past the plateau
     * measured on the sequential 1000-query run.
     */
    private static Fit fit(List<double[]> series) {
        Fit result = new Fit();
        int from = (int) Math.floor(series.size() * 0.2);
        int n = series.size() - from;
        result.points = n;
        if (n < 2) {
            return result;
        }
        double sumX = 0;
        double sumY = 0;
        double sumXY = 0;
        double sumXX = 0;
        result.min = Double.MAX_VALUE;
        result.max = -Double.MAX_VALUE;
        for (int i = from; i < series.size(); i++) {
            double x = series.get(i)[0];
            double y = series.get(i)[1];
            sumX += x;
            sumY += y;
            sumXY += x * y;
            sumXX += x * x;
            result.min = Math.min(result.min, y);
            result.max = Math.max(result.max, y);
        }
        double denominator = n * sumXX - sumX * sumX;
        result.slopePerHour = denominator == 0 ? 0 : (n * sumXY - sumX * sumY) / denominator * 3600.0;
        result.first = series.get(from)[1];
        result.last = series.get(series.size() - 1)[1];

        // The ceiling of each half of the fit window. This, and not the slope, is what the
        // memory series are judged on -- see "Why the ceiling and not the slope" below.
        int middle = from + n / 2;
        result.ceilingFirstHalf = -Double.MAX_VALUE;
        result.ceilingSecondHalf = -Double.MAX_VALUE;
        for (int i = from; i < middle; i++) {
            result.ceilingFirstHalf = Math.max(result.ceilingFirstHalf, series.get(i)[1]);
        }
        for (int i = middle; i < series.size(); i++) {
            result.ceilingSecondHalf = Math.max(result.ceilingSecondHalf, series.get(i)[1]);
        }
        return result;
    }

    private static List<double[]> series(int column) {
        List<double[]> points = new ArrayList<>();
        synchronized (samples) {
            for (Sample sample : samples) {
                double y;
                switch (column) {
                    case 0: y = sample.rss; break;
                    case 1: y = sample.footprint; break;
                    case 2: y = sample.heapUsed; break;
                    default: y = sample.handlesTotal(); break;
                }
                if (y >= 0) {
                    points.add(new double[] {sample.elapsedSeconds, y});
                }
            }
        }
        return points;
    }

    /**
     * The memory and handle criteria, applied to a set of fits.
     *
     * <h2>Why the ceiling and not the slope</h2>
     * The first version of this asserted a least squares slope over the fit window, and the
     * first 75-minute run failed it at +93.42 MB/h of {@code phys_footprint} — while RSS over
     * the same window fell at 68.88 MB/h and the handle count was flat. The series turned out
     * to be a bounded oscillation, not a trend: over 75 minutes {@code phys_footprint} moved
     * inside 466–593 MB with a period of roughly twenty minutes, so the fitted slope depends
     * entirely on where the window happens to start and stop. Same data, three windows:
     *
     * <pre>
     *   whole run    +46.48 MB/h
     *   last 80%     +93.42 MB/h      &lt;- what the run was failed on
     *   last 50%     -68.16 MB/h      &lt;- the opposite conclusion
     * </pre>
     *
     * A least squares fit is the wrong statistic for a signal whose period is comparable to the
     * window. The ceiling is the right one, because a leak and an oscillation differ in exactly
     * that respect: an oscillation has a ceiling and a leak does not. Highest value in the first
     * half of the fit window against the highest in the second, same data:
     *
     * <pre>
     *   75-minute clean run     rss  -12.4 MB   phys_footprint   +3.9 MB   handles  +1
     *   10-minute clean run     rss   +0.2 MB   phys_footprint  -34.2 MB   handles  +2
     *   10-minute leak fault    rss  +51.1 MB   phys_footprint +234.1 MB   handles +41
     * </pre>
     *
     * Which is a clean separation and, unlike the slope, one that does not depend on window
     * placement. The default threshold of 32 MB sits eight times above the clean measurement
     * and seven times below the fault. At the throughput measured — 482,442 iterations in 75
     * minutes — it still catches a leak of about 70 bytes per iteration.
     *
     * <p>The slopes are still computed and printed, because they are the right first thing to
     * look at when something has moved. They are diagnostics, not the gate.
     *
     * <h2>The handle thresholds, which were wrong for the same reason</h2>
     * The handle slope started at 0.50/h — "half a handle an hour, surely generous" — and a
     * clean 66-minute run failed it at +0.53/h with every other signal healthy and the handle
     * count back to zero at the end. The live count is not a monotone quantity either: the pool
     * opens and evicts connections on its own schedule, so it wanders between 7 and 17 across a
     * window. For a counter swinging by ten over fifty minutes with 69 samples, one standard
     * error on the fitted slope is about 1.4/h, so a 0.50/h threshold sits well inside the
     * statistic's own noise and was always going to flake.
     *
     * <p>Measured instead, over the fit window of every run long enough to fit:
     *
     * <pre>
     *   clean, 66 minutes     slope +0.53/h    ceiling 14 -&gt; 17  (+3)
     *   clean, 75 minutes     slope +0.27/h    ceiling 15 -&gt; 16  (+1)
     *   clean, 10 minutes     slope -10.24/h   ceiling  (+2)
     *   leak fault, run 1     slope +410.19/h  ceiling 55 -&gt; 96  (+41)
     *   leak fault, run 2     slope +560.29/h  ceiling 70 -&gt; 103 (+33)
     * </pre>
     *
     * So the slope threshold is 25/h — roughly eighteen standard errors above the noise and
     * sixteen times below the smallest fault — and the ceiling threshold is 16, five times above
     * the largest clean rise and twice below the smallest fault. Both are asserted, because each
     * covers the other's blind spot.
     *
     * <p>Neither is the primary defence. That is the unconditional check that all three handle
     * counts are zero once the pools have closed, which has no threshold to get wrong and is the
     * same assertion {@code NativeTestBase} makes after every test. The two window statistics
     * exist to catch a leak that something happens to clean up before the end.
     */
    /**
     * The shortest fit window the memory ceiling is asserted on, in seconds.
     *
     * <p>The ceiling is only a meaningful statistic once each half of the window has seen enough
     * of the oscillation to have found its top. Measured ceiling rises on clean runs, by window
     * length:
     *
     * <pre>
     *    3 minutes    +37.88 MB   -- three footprint samples per half; meaningless
     *   10 minutes    -34.20 MB
     *   66 minutes     -2.39 MB
     *   75 minutes     +3.91 MB
     * </pre>
     *
     * So a three-minute run fails a 32 MB threshold on phase alone, and the two long windows
     * agree within 4 MB. Thirty minutes of fit window is the guard: comfortably past the point
     * where the statistic settles, and far below the 1-6 hours the gate asks for, so it never
     * fires on a gate run. Below it the ceilings are printed and not asserted, which is the
     * honest thing — a criterion that cannot mean anything yet should say so rather than
     * produce a verdict.
     */
    private static final long MIN_MEMORY_FIT_SECONDS = 1800;

    /** Why the memory ceiling was not asserted, or null when it was. */
    private static String memoryNotJudged;

    /** Seconds spanned by the fit window, or 0 when there is not one. */
    private static long fitWindowSeconds() {
        synchronized (samples) {
            if (samples.size() < 2) {
                return 0;
            }
            int from = (int) Math.floor(samples.size() * 0.2);
            return samples.get(samples.size() - 1).elapsedSeconds - samples.get(from).elapsedSeconds;
        }
    }

    private static void judgeMemory(List<String> failures, Fit rss, Fit footprint, Fit handles) {
        // Handles are judged at any window length: the counter is not a cache and does not need
        // a long window to have found its top.
        if (handles.points >= 4 && handles.ceilingRise() > maxHandleCeilingRise) {
            failures.add(String.format(
                    Locale.ROOT,
                    "the native handle ceiling rose %.0f across the window, above the %.0f"
                            + " threshold (%.0f -> %.0f)",
                    handles.ceilingRise(), maxHandleCeilingRise,
                    handles.ceilingFirstHalf, handles.ceilingSecondHalf));
        }
        if (handles.slopePerHour > maxHandleSlopePerHour) {
            failures.add(String.format(
                    Locale.ROOT, "native handle slope %.2f/h is above the %.2f/h threshold",
                    handles.slopePerHour, maxHandleSlopePerHour));
        }

        long span = fitWindowSeconds();
        if (span < MIN_MEMORY_FIT_SECONDS) {
            memoryNotJudged = "the fit window spans " + span + "s, under the "
                    + MIN_MEMORY_FIT_SECONDS + "s the memory ceiling needs to mean anything, so"
                    + " the RSS and phys_footprint ceilings above were printed and not asserted";
            return;
        }
        if (rss.points >= 4 && rss.ceilingRise() / 1048576.0 > maxCeilingRiseMb) {
            failures.add(String.format(
                    Locale.ROOT,
                    "the rss ceiling rose %.2f MB across the window, above the %.2f MB threshold"
                            + " (%.1f MB -> %.1f MB)",
                    rss.ceilingRise() / 1048576.0, maxCeilingRiseMb,
                    rss.ceilingFirstHalf / 1048576.0, rss.ceilingSecondHalf / 1048576.0));
        }
        if (footprint.points >= 4 && footprint.ceilingRise() / 1048576.0 > maxCeilingRiseMb) {
            failures.add(String.format(
                    Locale.ROOT,
                    "the phys_footprint ceiling rose %.2f MB across the window, above the %.2f MB"
                            + " threshold (%.1f MB -> %.1f MB)",
                    footprint.ceilingRise() / 1048576.0, maxCeilingRiseMb,
                    footprint.ceilingFirstHalf / 1048576.0, footprint.ceilingSecondHalf / 1048576.0));
        }
    }

    private static String describeFit(String label, Fit f, double divisor, String unit) {
        return String.format(
                Locale.ROOT,
                "  %-16s %4d pts  slope %+9.2f %s/h  ceiling %8.2f -> %8.2f (%+8.2f)"
                        + "  min %8.2f  max %8.2f",
                label, f.points, f.slopePerHour / divisor, unit,
                (f.ceilingFirstHalf == -Double.MAX_VALUE ? 0 : f.ceilingFirstHalf) / divisor,
                (f.ceilingSecondHalf == -Double.MAX_VALUE ? 0 : f.ceilingSecondHalf) / divisor,
                f.ceilingRise() / divisor,
                (f.min == Double.MAX_VALUE ? 0 : f.min) / divisor,
                (f.max == -Double.MAX_VALUE ? 0 : f.max) / divisor);
    }

    private static int verdict() {
        StringBuilder text = new StringBuilder();
        List<String> failures = new ArrayList<>();

        Fit rss = fit(series(0));
        Fit footprint = fit(series(1));
        Fit heap = fit(series(2));
        Fit handles = fit(series(3));

        text.append("=== slope over the last 80% of the window ===\n");
        text.append(describeFit("rss", rss, 1048576.0, "MB")).append('\n');
        text.append(describeFit("phys_footprint", footprint, 1048576.0, "MB")).append('\n');
        text.append(describeFit("heap used", heap, 1048576.0, "MB")).append('\n');
        text.append(describeFit("native handles", handles, 1.0, "handles")).append('\n');

        long finalConnection = ChdbNative.openHandleCount(ChdbNative.KIND_CONNECTION);
        long finalResult = ChdbNative.openHandleCount(ChdbNative.KIND_RESULT);
        long finalStream = ChdbNative.openHandleCount(ChdbNative.KIND_STREAM);

        text.append("\n=== outcomes ===\n");
        synchronized (outcomes) {
            List<String> keys = new ArrayList<>(outcomes.keySet());
            Collections.sort(keys);
            for (String key : keys) {
                text.append(String.format(Locale.ROOT, "  %-52s %10d%n", key, outcomes.get(key).get()));
            }
        }
        text.append(String.format(Locale.ROOT, "  %-52s %10d%n", "TOTAL iterations", iterations.get()));
        text.append(String.format(Locale.ROOT, "  %-52s %10d%n", "TOTAL rows read", rowsRead.get()));
        text.append(String.format(Locale.ROOT, "  %-52s %10d%n", "TOTAL unexpected failures", unexpected.get()));
        text.append(String.format(
                Locale.ROOT, "  %-52s %10s%n", "handles after the pools closed",
                finalConnection + "/" + finalResult + "/" + finalStream));
        text.append(String.format(
                Locale.ROOT, "  %-52s %10d%n", "engine-floor samples (every 5 ms)",
                engineFloorSamples.get()));
        text.append(String.format(
                Locale.ROOT, "  %-52s %10d%n", "of those, zero connections open (engine down)",
                zeroConnectionObservations.get()));
        text.append(String.format(
                Locale.ROOT, "  %-52s %10d%n", "engine restarts observed (0 -> 1 transitions)",
                engineBoots.get()));
        text.append(String.format(
                Locale.ROOT, "  %-52s %10d%n", "lowest connection count seen",
                minConnectionHandles == Long.MAX_VALUE ? -1 : minConnectionHandles));

        if (!firstErrors.isEmpty()) {
            text.append("\n=== first unexpected failures ===\n");
            synchronized (firstErrors) {
                for (String error : firstErrors) {
                    text.append("  ").append(error).append('\n');
                }
            }
        }

        // The steady arm's whole premise is that the engine booted once, so that what the run
        // measured was this driver rather than the engine-restart hazard chdb-core documents.
        // Asserted rather than assumed: a pool setting that quietly stopped working would
        // otherwise turn a clean result into a claim about the wrong thing.
        if ("steady".equals(arm) && engineFloorSamples.get() > 0
                && zeroConnectionObservations.get() > 0) {
            failures.add(
                    "the connection count reached zero " + zeroConnectionObservations.get()
                            + " times and the engine restarted " + engineBoots.get()
                            + " times, so this run was not the steady arm it claims to be -- see"
                            + " the pin in main()");
        }

        // A run that measured nothing must not report success -- the same discipline
        // run-signal-window-test.sh applies to its own zero.
        if (stallReport != null) {
            failures.add("a worker stalled: " + stallReport + " (see stall-report.txt)");
        }
        if (samples.size() < MIN_SAMPLES) {
            failures.add("only " + samples.size() + " samples; a slope needs at least " + MIN_SAMPLES);
        }
        if (iterations.get() < MIN_ITERATIONS) {
            failures.add("only " + iterations.get() + " iterations; at least " + MIN_ITERATIONS + " are needed");
        }
        synchronized (outcomes) {
            for (String shape : SHAPES) {
                boolean seen = false;
                for (String key : outcomes.keySet()) {
                    if (key.startsWith(shape + ":")) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    failures.add("shape " + shape + " never ran, so the mix did not cover it");
                }
            }
            // Having run the shape is not the same as having exercised the mechanism. A cancel
            // that always lost the race, or a timeout whose query always finished inside the
            // budget, reports a shape that ran and a mechanism that was never touched -- and
            // those three mechanisms are the ones the gate is named after. So each has to have
            // fired at least once for the run to count.
            for (String required :
                    new String[] {
                        "cancel:cancelled", "timeout-stream:timed-out", "timeout-open:timed-out"
                    }) {
                AtomicLong counter = outcomes.get(required);
                if (counter == null || counter.get() == 0) {
                    failures.add(
                            required + " never happened, so that mechanism was not exercised"
                                    + " -- the query is too fast for the budget on this host");
                }
            }
        }
        if (unexpected.get() > MAX_UNEXPECTED) {
            failures.add(
                    unexpected.get() + " unexpected failures over " + iterations.get()
                            + " iterations; the allowance is " + MAX_UNEXPECTED
                            + " and the first twenty are above with their stacks");
        }
        if (finalConnection != 0 || finalResult != 0 || finalStream != 0) {
            failures.add("native handles did not return to zero: " + finalConnection + " connection, "
                    + finalResult + " result, " + finalStream + " stream");
        }
        judgeMemory(failures, rss, footprint, handles);

        text.append('\n');
        if (memoryNotJudged != null) {
            text.append("NOT JUDGED: ").append(memoryNotJudged).append('\n');
        }
        if (failures.isEmpty()) {
            text.append(memoryNotJudged == null
                    ? "VERDICT=clean\n"
                    : "VERDICT=clean (handles and workload; memory ceiling not asserted)\n");
        } else {
            text.append("VERDICT=failed\n");
            for (String failure : failures) {
                text.append("  - ").append(failure).append('\n');
            }
        }

        String summary = text.toString();
        System.out.print(summary);
        try {
            Files.write(out.resolve("verdict.txt"), summary.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            System.out.println("could not write the verdict: " + e);
        }
        if (stallReport != null) {
            return 3;
        }
        return failures.isEmpty() ? 0 : 2;
    }

    // ---------------------------------------------------------------- after the fact

    /**
     * Re-judges a {@code samples.csv} from a finished run, without running one.
     *
     * <p>Exists because the series is the evidence and the criterion is a judgement about it,
     * and those two things change on different schedules. A CI artifact from three weeks ago can
     * be re-read against today's thresholds; a run whose criterion turned out to be the wrong
     * statistic — which is what happened to the first 75-minute window, see {@link
     * #judgeMemory} — does not have to be repeated to find out what the right one says about it.
     *
     * <p>It judges only what the file contains: the memory and handle criteria. Outcome counts,
     * the shape coverage check and the end-of-run handle count are properties of a live run and
     * are reported as not checked rather than silently passed.
     */
    private static int analyze(Path directory) throws IOException {
        Path csv = Files.isDirectory(directory) ? directory.resolve("samples.csv") : directory;
        List<String> lines = Files.readAllLines(csv, StandardCharsets.UTF_8);
        if (lines.size() < 2) {
            System.out.println("VERDICT=failed  " + csv + " has no samples");
            return 2;
        }
        for (String line : lines.subList(1, lines.size())) {
            String[] f = line.split(",");
            if (f.length < 9) {
                continue;
            }
            Sample sample = new Sample();
            sample.elapsedSeconds = Long.parseLong(f[0].trim());
            sample.rss = Long.parseLong(f[1].trim());
            sample.footprint = Long.parseLong(f[2].trim());
            sample.heapUsed = Long.parseLong(f[3].trim());
            sample.handlesConnection = Long.parseLong(f[4].trim());
            sample.handlesResult = Long.parseLong(f[5].trim());
            sample.handlesStream = Long.parseLong(f[6].trim());
            sample.liveThreads = Integer.parseInt(f[7].trim());
            sample.iterations = Long.parseLong(f[8].trim());
            samples.add(sample);
        }

        Fit rss = fit(series(0));
        Fit footprint = fit(series(1));
        Fit heap = fit(series(2));
        Fit handles = fit(series(3));
        StringBuilder text = new StringBuilder();
        text.append("re-analysing ").append(csv).append(", ").append(samples.size())
                .append(" samples\nthresholds: memory ceiling ").append(maxCeilingRiseMb)
                .append(" MB, handle ceiling ").append(maxHandleCeilingRise)
                .append(", handle slope ").append(maxHandleSlopePerHour)
                .append("/h\n\n=== slope and ceiling over the last 80% of the window ===\n");
        text.append(describeFit("rss MB", rss, 1048576.0, "MB")).append('\n');
        text.append(describeFit("phys_footprint MB", footprint, 1048576.0, "MB")).append('\n');
        text.append(describeFit("heap used MB", heap, 1048576.0, "MB")).append('\n');
        text.append(describeFit("native handles", handles, 1.0, "handles")).append('\n');

        List<String> failures = new ArrayList<>();
        if (samples.size() < MIN_SAMPLES) {
            failures.add("only " + samples.size() + " samples; a fit needs at least " + MIN_SAMPLES);
        }
        judgeMemory(failures, rss, footprint, handles);

        text.append("\nnot checked, because a recorded series cannot answer them: outcome counts,"
                + " shape coverage, unexpected failures, handles after close\n\n");
        if (failures.isEmpty()) {
            text.append("VERDICT=clean (memory and handles only)\n");
        } else {
            text.append("VERDICT=failed\n");
            for (String failure : failures) {
                text.append("  - ").append(failure).append('\n');
            }
        }
        System.out.print(text);
        return failures.isEmpty() ? 0 : 2;
    }

    // ---------------------------------------------------------------- entry point

    public static void main(String[] args) throws Exception {
        Map<String, String> options = new LinkedHashMap<>();
        for (int i = 0; i + 1 < args.length; i += 2) {
            options.put(args[i], args[i + 1]);
        }
        durationMillis = TimeUnit.MINUTES.toMillis(Long.parseLong(options.getOrDefault("--minutes", "60")));
        threads = Integer.parseInt(options.getOrDefault("--threads", "8"));
        sampleMillis = TimeUnit.SECONDS.toMillis(Long.parseLong(options.getOrDefault("--sample-seconds", "15")));
        stallMillis = TimeUnit.SECONDS.toMillis(Long.parseLong(options.getOrDefault("--stall-seconds", "180")));
        fault = options.getOrDefault("--fault", "none");
        arm = options.getOrDefault("--arm", "steady");
        url = options.getOrDefault("--url", "jdbc:chdb::memory:");
        out = Paths.get(options.getOrDefault("--out", "target/soak"));
        maxCeilingRiseMb = Double.parseDouble(options.getOrDefault("--max-ceiling-rise", "32"));
        maxHandleSlopePerHour = Double.parseDouble(options.getOrDefault("--max-handle-slope", "25"));
        maxHandleCeilingRise = Double.parseDouble(options.getOrDefault("--max-handle-ceiling-rise", "16"));

        if (options.containsKey("--analyze")) {
            System.exit(analyze(Paths.get(options.get("--analyze"))));
        }

        Files.createDirectories(out);

        System.out.printf(
                Locale.ROOT,
                "soak: %d minutes, %d workers, url %s, sampling every %ds, stall window %ds, fault %s%n",
                durationMillis / 60000, threads, url, sampleMillis / 1000, stallMillis / 1000, fault);
        System.out.println("soak: pid " + pid() + ", output in " + out.toAbsolutePath());

        progress = new AtomicLong[threads];
        for (int i = 0; i < threads; i++) {
            progress[i] = new AtomicLong();
        }

        // Connect once before anything is timed, so a library that will not load fails as setup
        // rather than as a workload error rate.
        try (Connection connection = DriverManager.getConnection(url);
                Statement statement = connection.createStatement();
                ResultSet rs = statement.executeQuery("SELECT version()")) {
            rs.next();
            System.out.println("soak: engine " + rs.getString(1)
                    + ", JNI ABI " + ChdbNative.jniAbiVersion());
        } catch (SQLException e) {
            System.out.println("VERDICT=setup-failed " + e);
            System.exit(5);
        }

        // The pin. Taken before the pool exists and released after every worker has stopped, so
        // that for the whole window at least one connection is open and the engine is booted
        // exactly once. Outside the pool on purpose: making this depend on HikariCP's idle and
        // max-lifetime bookkeeping would make the premise of the whole run depend on getting
        // three pool settings right, and HikariCP's own default maxLifetime is 30 minutes, which
        // an hour-long window crosses. A connection this process holds itself cannot be retired
        // by anything.
        if ("steady".equals(arm)) {
            pinnedConnection = DriverManager.getConnection(url);
            try (Statement statement = pinnedConnection.createStatement();
                    ResultSet rs = statement.executeQuery("SELECT 1")) {
                rs.next();
            }
            System.out.println("soak: pinned one connection for the window; the engine boots once");
        } else {
            System.out.println("soak: NO pinned connection -- this arm lets the pool drain to zero"
                    + " and the engine restart, which is the known-hazardous shape");
        }

        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(url);
        config.setMaximumPoolSize(threads);
        if ("steady".equals(arm)) {
            // One connection always retained, plus the pin. Lifetime churn is kept, because
            // retiring and replacing a pooled connection is coverage worth having -- it just
            // must not be able to take the last connection in the process with it.
            config.setMinimumIdle(1);
            config.setIdleTimeout(TimeUnit.SECONDS.toMillis(30));
            config.setMaxLifetime(TimeUnit.MINUTES.toMillis(2));
        } else {
            // Deliberately the configuration that drains: minimumIdle=0 with a short idle
            // timeout. This is not an exotic setting -- it is what a low-traffic service is
            // routinely configured with, which is exactly why the arm exists.
            config.setMinimumIdle(0);
            config.setIdleTimeout(TimeUnit.SECONDS.toMillis(1));
            config.setMaxLifetime(TimeUnit.SECONDS.toMillis(30));
        }
        config.setConnectionTimeout(TimeUnit.SECONDS.toMillis(30));
        config.setPoolName("chdb-soak");
        pool = new HikariDataSource(config);

        cancellers = Executors.newScheduledThreadPool(2, runnable -> {
            Thread thread = new Thread(runnable, "soak-canceller");
            thread.setDaemon(true);
            return thread;
        });

        long start = System.currentTimeMillis();
        long deadline = start + durationMillis;

        List<Thread> workers = new ArrayList<>();
        for (int i = 0; i < threads; i++) {
            final int index = i;
            Thread thread = new Thread(() -> worker(index, deadline), "soak-worker-" + i);
            workers.add(thread);
        }
        Thread sampler = new Thread(() -> sampler(start, deadline), "soak-sampler");
        sampler.setDaemon(true);
        Thread watchdog = new Thread(() -> watchdog(deadline), "soak-watchdog");
        watchdog.setDaemon(true);
        Thread engineFloor = new Thread(() -> engineFloorWatcher(deadline), "soak-engine-floor");
        engineFloor.setDaemon(true);

        for (Thread thread : workers) {
            thread.start();
        }
        sampler.start();
        watchdog.start();
        engineFloor.start();
        if ("pool-drain".equals(arm)) {
            Thread cycler = new Thread(() -> quietCycler(deadline), "soak-quiet-cycler");
            cycler.setDaemon(true);
            cycler.start();
        }

        // A stalled worker never returns, so this cannot be a plain join: it polls, and stops
        // waiting the moment the watchdog has reported. Without that, a fault run would sit out
        // the rest of its window after the finding it exists to produce.
        long joinUntil = deadline + 120000;
        for (Thread thread : workers) {
            while (thread.isAlive()
                    && stallReport == null
                    && System.currentTimeMillis() < joinUntil) {
                thread.join(1000);
            }
        }
        running = false;

        if (stallReport == null) {
            // Only worth closing cleanly on a run that is going to be judged on its handle
            // count. After a stall the process is being abandoned anyway.
            cancellers.shutdownNow();
            pool.close();
            // The pin goes last, so the engine is torn down once, at the end, by us -- and so
            // the handle count can legitimately reach zero for the final assertion.
            if (pinnedConnection != null) {
                pinnedConnection.close();
            }
            System.out.println("soak: pool closed, pin released, " + leaked.size()
                    + " objects deliberately leaked");
        }

        System.exit(verdict());
    }
}
JAVA

# --------------------------------------------------------------------------------- setup

# --analyze reads a file and calls no native method, so it needs the classpath and the probe but
# not the engine. Checking for one would refuse to re-read a CI artifact on a machine that has
# never built the shim, which is most of the machines anyone would want to read it on.
if [ -z "$ANALYZE" ]; then
  [ -f "${RUNTIME}/libchdb.so" ] || die "no engine in ${RUNTIME}; build the platform package first
  mvn -pl chdb-jdbc -am compile && scripts/build-native.sh ${DEFAULT_PLATFORM}"
fi
[ -x "$JAVA_BIN" ] || command -v "$JAVA_BIN" >/dev/null 2>&1 || die "no java at ${JAVA_BIN}"

# Not in --analyze mode, which writes nothing: creating the directory there would litter
# target/soak with empty timestamped runs every time somebody re-read an old one.
if [ -z "$ANALYZE" ]; then
  if [ -z "$OUT" ]; then
    OUT="${ROOT}/target/soak/$(date -u +%Y%m%dT%H%M%SZ)-${ARM}-${FAULT}"
  fi
  mkdir -p "$OUT"
fi

# The classpath is built from the reactor, not from ~/.m2, and then cut down to the three jars
# the probe actually needs. Both halves matter. Resolving through the reactor is what makes
# chdb-jdbc/target/classes win over any chdb-jdbc jar a different branch installed locally --
# mixing those is how you get "chDB JNI ABI mismatch" from a tree that builds fine. Cutting it
# down to HikariCP and slf4j is belt and braces: with no chdb jar on the classpath at all,
# there is nothing for the loader to pick up by accident.
#
# The three-line "Failed to load class org.slf4j.impl.StaticLoggerBinder" banner at startup is
# expected and is not worth chasing: the reactor resolves slf4j-api 1.7 and slf4j-nop 2.0, which
# are different binding generations, so 1.7 finds no binder and says so before falling back to
# the no-op logger it would have used anyway. HikariCP logs nothing either way.
printf 'run-soak-test: resolving the classpath from the reactor\n'
CP_FILE="${ROOT}/target/soak-cp.txt"
(cd "$ROOT" && mvn -B -ntp -q -pl chdb-integration-tests -am compile \
    dependency:build-classpath -Dmdep.outputFile=target/soak-cp.raw.txt -Dmdep.includeScope=test) \
  || die "could not resolve the integration-test classpath"
RAW="${ROOT}/chdb-integration-tests/target/soak-cp.raw.txt"
[ -f "$RAW" ] || die "maven wrote no classpath to ${RAW}"

CP=""
while IFS= read -r entry; do
  case "$entry" in
    */chdb-jdbc/target/classes|*/HikariCP-*.jar|*/slf4j-api-*.jar|*/slf4j-nop-*.jar)
      CP="${CP:+${CP}:}${entry}" ;;
  esac
done < <(tr ':' '\n' < "$RAW")
printf '%s\n' "$CP" > "$CP_FILE"
case "$CP" in
  *chdb-jdbc/target/classes*) ;;
  *) die "the resolved classpath has no chdb-jdbc/target/classes; run 'mvn -pl chdb-jdbc -am compile'" ;;
esac
case "$CP" in
  *HikariCP-*) ;;
  *) die "the resolved classpath has no HikariCP jar" ;;
esac
printf 'run-soak-test: classpath\n'
printf '%s\n' "$CP" | tr ':' '\n' | sed 's/^/  /'

printf 'run-soak-test: compiling the probe\n'
"$JAVAC_BIN" --release 11 -Xlint:-options -cp "$CP" -d "$PROBE" "${PROBE}/SoakProbe.java"

# --------------------------------------------------------------------------------- analyze

if [ -n "$ANALYZE" ]; then
  exec "$JAVA_BIN" -cp "${CP}:${PROBE}" SoakProbe \
    --analyze "$ANALYZE" \
    --max-ceiling-rise "$MAX_CEILING_RISE" \
    --max-handle-slope "$MAX_HANDLE_SLOPE" \
    --max-handle-ceiling-rise "$MAX_HANDLE_CEILING_RISE"
fi

# --------------------------------------------------------------------------------- run

printf 'run-soak-test: engine\n'
sed 's/^/  /' "${RUNTIME}/manifest.properties" 2>/dev/null || true

printf '\nrun-soak-test: starting a %s minute run, output in %s\n\n' "$MINUTES" "$OUT"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

set +e
"$JAVA_BIN" \
  "-Xmx${XMX}" \
  -XX:+HeapDumpOnOutOfMemoryError \
  "-XX:HeapDumpPath=${OUT}" \
  "-XX:ErrorFile=${OUT}/hs_err_pid%p.log" \
  "-Dchdb.library.path=${RUNTIME}" \
  -cp "${CP}:${PROBE}" \
  SoakProbe \
  --minutes "$MINUTES" \
  --threads "$THREADS" \
  --sample-seconds "$SAMPLE_SECONDS" \
  --stall-seconds "$STALL_SECONDS" \
  --fault "$FAULT" \
  --arm "$ARM" \
  --url "$URL" \
  --out "$OUT" \
  --max-ceiling-rise "$MAX_CEILING_RISE" \
  --max-handle-slope "$MAX_HANDLE_SLOPE" \
  --max-handle-ceiling-rise "$MAX_HANDLE_CEILING_RISE" \
  2>&1 | tee "${OUT}/soak.log"
STATUS=${PIPESTATUS[0]}
set -e

FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  printf 'started=%s\n' "$STARTED"
  printf 'finished=%s\n' "$FINISHED"
  printf 'minutes=%s\nthreads=%s\nfault=%s\nurl=%s\nexit=%s\n' \
    "$MINUTES" "$THREADS" "$FAULT" "$URL" "$STATUS"
  printf 'host=%s %s %s\n' "$(uname -s)" "$(uname -m)" "$(uname -r)"
  printf 'java=%s\n' "$("$JAVA_BIN" -version 2>&1 | head -1)"
  printf 'runtime=%s\n' "$RUNTIME"
} > "${OUT}/run.properties"

printf '\nrun-soak-test: exit %s, results in %s\n' "$STATUS" "$OUT"

case "$STATUS" in
  0) printf 'run-soak-test: clean\n' ;;
  2) printf 'run-soak-test: the run finished but failed its own thresholds -- see verdict.txt\n' ;;
  3) printf 'run-soak-test: a worker stalled -- see stall-report.txt\n' ;;
  5) printf 'run-soak-test: setup failed, so nothing was measured\n' ;;
  *)
    printf 'run-soak-test: the probe died (exit %s), which is itself a finding\n' "$STATUS"
    # A signal death with no hs_err report has one likely cause here, and it is worth naming
    # rather than leaving an operator to stare at 138. chdb_connect() resets SIGSEGV, SIGBUS,
    # SIGILL, SIGFPE and four more to SIG_DFL process-wide whenever the signal-handler opt-out
    # is armed -- which the driver arms once, for the whole process -- and the shim's restore
    # cannot be atomic against the JVM's other threads. In that window a signal HotSpot handles
    # for itself kills the process instead, and writes no report, because HotSpot's crash
    # reporter *is* the handler that was removed. This soak opens a connection per query, so it
    # drives that window harder than anything else in the repository. Issue #14.
    if [ "$STATUS" -gt 128 ] 2>/dev/null; then
      SIGNAL=$((STATUS - 128))
      case "$SIGNAL" in
        4) NAME=SIGILL ;;  6) NAME=SIGABRT ;;  8) NAME=SIGFPE ;;
        10) NAME=SIGBUS ;; 11) NAME=SIGSEGV ;; 9) NAME=SIGKILL ;;
        *) NAME="signal ${SIGNAL}" ;;
      esac
      printf 'run-soak-test: killed by %s\n' "$NAME"
      if ls "${OUT}"/hs_err_pid*.log >/dev/null 2>&1; then
        printf 'run-soak-test: HotSpot wrote a report, so its handler was installed:\n'
        ls "${OUT}"/hs_err_pid*.log | sed 's/^/  /'
      else
        case "$NAME" in
          SIGBUS|SIGSEGV|SIGILL|SIGFPE)
            printf 'run-soak-test: and no hs_err report, which is the issue #14 signature --\n'
            printf '  a host handler that was at SIG_DFL inside chdb_connect(). Confirm the\n'
            printf '  window is still open on this engine with:\n'
            printf '    scripts/run-signal-window-test.sh measure\n'
            printf '  A non-zero hostHandlersAtSigDfl there means this crash needs no other\n'
            printf '  explanation. It is upstream; nothing in this repository closes it.\n'
            ;;
        esac
      fi
    fi
    ;;
esac
exit "$STATUS"
