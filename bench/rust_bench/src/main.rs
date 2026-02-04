//! Tokio Benchmark Suite for comparison with blitz-io
//!
//! This benchmark measures Tokio's async runtime performance for direct
//! comparison with blitz-io's Zig implementation.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot, Barrier, Mutex, Notify, RwLock, Semaphore};

// ============================================================================
// Configuration
// ============================================================================

const ITERATIONS: usize = 10;
const WARMUP_ITERATIONS: usize = 3;
const BENCHMARK_SIZE: usize = 100_000;
const CHANNEL_SIZE: usize = 1000;
const NUM_WORKERS: usize = 4;

// ============================================================================
// Statistics
// ============================================================================

struct Stats {
    min_ns: u64,
    max_ns: u64,
    total_ns: u64,
    count: usize,
}

impl Stats {
    fn new() -> Self {
        Stats {
            min_ns: u64::MAX,
            max_ns: 0,
            total_ns: 0,
            count: 0,
        }
    }

    fn add(&mut self, ns: u64) {
        self.min_ns = self.min_ns.min(ns);
        self.max_ns = self.max_ns.max(ns);
        self.total_ns += ns;
        self.count += 1;
    }

    fn avg_ns(&self) -> u64 {
        if self.count > 0 {
            self.total_ns / self.count as u64
        } else {
            0
        }
    }

    fn ns_per_op(&self, ops: usize) -> f64 {
        self.avg_ns() as f64 / ops as f64
    }

    fn ops_per_sec(&self, ops: usize) -> f64 {
        let avg_ns = self.avg_ns();
        if avg_ns == 0 {
            return 0.0;
        }
        ops as f64 * 1_000_000_000.0 / avg_ns as f64
    }
}

// ============================================================================
// JSON Output
// ============================================================================

#[derive(Default, serde::Serialize)]
struct JsonOutput {
    // Task spawning
    spawn_ns: f64,
    spawn_batch_ns: f64,
    spawn_ops_per_sec: f64,

    // Channel operations
    channel_send_ns: f64,
    channel_recv_ns: f64,
    channel_roundtrip_ns: f64,
    channel_mpmc_ns: f64,
    oneshot_ns: f64,
    mpmc_lockfree_ns: f64,

    // Synchronization
    mutex_ns: f64,
    mutex_contention_ns: f64,
    rwlock_read_ns: f64,
    rwlock_write_ns: f64,
    rwlock_contention_ns: f64,
    semaphore_ns: f64,
    semaphore_contention_ns: f64,
    barrier_ns: f64,

    // Parking primitives
    parker_ns: f64,
    notify_ns: f64,

    // Timers
    timer_precision_ns: f64,

    // Throughput
    task_throughput: f64,
    message_throughput: f64,

    // Memory (placeholder - Rust doesn't easily expose this)
    peak_memory_kb: u64,
    total_allocations: u64,

    // Metadata
    benchmark_size: u64,
    iterations: u64,
    warmup_iterations: u64,
    num_workers: u64,
}

// ============================================================================
// Main
// ============================================================================

fn main() {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(NUM_WORKERS)
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        run_benchmarks().await;
    });
}

async fn run_benchmarks() {
    let mut output = JsonOutput::default();
    output.benchmark_size = BENCHMARK_SIZE as u64;
    output.iterations = ITERATIONS as u64;
    output.warmup_iterations = WARMUP_ITERATIONS as u64;
    output.num_workers = NUM_WORKERS as u64;

    // Task spawn benchmark
    output.spawn_ns = bench_task_spawn().await;
    output.spawn_ops_per_sec = BENCHMARK_SIZE as f64 * 1_000_000_000.0 /
        (output.spawn_ns * BENCHMARK_SIZE as f64);

    // Batch spawn benchmark
    output.spawn_batch_ns = bench_task_spawn_batch().await;

    // Channel benchmarks
    let (send_ns, recv_ns) = bench_channel_throughput().await;
    output.channel_send_ns = send_ns;
    output.channel_recv_ns = recv_ns;
    output.channel_roundtrip_ns = bench_channel_roundtrip().await;
    output.channel_mpmc_ns = bench_channel_mpmc().await;
    output.oneshot_ns = bench_oneshot().await;
    output.mpmc_lockfree_ns = bench_mpmc_lockfree().await;
    output.message_throughput = CHANNEL_SIZE as f64 * 2.0 * 1_000_000_000.0 /
        ((send_ns + recv_ns) * CHANNEL_SIZE as f64);

    // Synchronization benchmarks
    output.mutex_ns = bench_mutex_uncontended().await;
    output.mutex_contention_ns = bench_mutex_contention().await;
    output.rwlock_read_ns = bench_rwlock_read().await;
    output.rwlock_write_ns = bench_rwlock_write().await;
    output.rwlock_contention_ns = bench_rwlock_contention().await;
    output.semaphore_ns = bench_semaphore().await;
    output.semaphore_contention_ns = bench_semaphore_contention().await;
    output.barrier_ns = bench_barrier().await;
    output.parker_ns = bench_parker().await;
    output.notify_ns = bench_notify().await;

    // Timer precision
    output.timer_precision_ns = bench_timer_precision().await;

    // Task throughput
    output.task_throughput = bench_task_throughput().await;

    // Print JSON output
    println!("{}", serde_json::to_string_pretty(&output).unwrap());
}

// ============================================================================
// Task Spawn Benchmarks
// ============================================================================

async fn bench_task_spawn() -> f64 {
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();

        // Spawn many tasks and await them
        let mut handles = Vec::with_capacity(BENCHMARK_SIZE);
        for i in 0..BENCHMARK_SIZE {
            let handle = tokio::spawn(async move {
                std::hint::black_box(i);
            });
            handles.push(handle);
        }

        // Wait for all to complete
        for handle in handles {
            let _ = handle.await;
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(BENCHMARK_SIZE)
}

async fn bench_task_spawn_batch() -> f64 {
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();

        // Spawn tasks in batches
        let batch_size = 1000;
        for _ in 0..(BENCHMARK_SIZE / batch_size) {
            let mut handles = Vec::with_capacity(batch_size);
            for i in 0..batch_size {
                let handle = tokio::spawn(async move {
                    std::hint::black_box(i);
                });
                handles.push(handle);
            }
            for handle in handles {
                let _ = handle.await;
            }
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(BENCHMARK_SIZE)
}

// ============================================================================
// Channel Benchmarks
// ============================================================================

async fn bench_channel_throughput() -> (f64, f64) {
    // Send benchmark
    let send_ns = {
        let mut stats = Stats::new();

        for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
            let (tx, mut rx) = mpsc::channel(CHANNEL_SIZE);

            let start = Instant::now();

            // Send all
            for i in 0..CHANNEL_SIZE {
                tx.send(i).await.unwrap();
            }

            let send_elapsed = start.elapsed().as_nanos() as u64;

            // Drain
            for _ in 0..CHANNEL_SIZE {
                rx.recv().await;
            }

            if iter >= WARMUP_ITERATIONS {
                stats.add(send_elapsed);
            }
        }

        stats.ns_per_op(CHANNEL_SIZE)
    };

    // Recv benchmark
    let recv_ns = {
        let mut stats = Stats::new();

        for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
            let (tx, mut rx) = mpsc::channel(CHANNEL_SIZE);

            // Fill first
            for i in 0..CHANNEL_SIZE {
                tx.send(i).await.unwrap();
            }

            let start = Instant::now();

            // Receive all
            for _ in 0..CHANNEL_SIZE {
                rx.recv().await;
            }

            let elapsed = start.elapsed().as_nanos() as u64;
            if iter >= WARMUP_ITERATIONS {
                stats.add(elapsed);
            }
        }

        stats.ns_per_op(CHANNEL_SIZE)
    };

    (send_ns, recv_ns)
}

async fn bench_channel_roundtrip() -> f64 {
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let (tx, mut rx) = mpsc::channel(1);

        let start = Instant::now();

        for i in 0..CHANNEL_SIZE {
            tx.send(i).await.unwrap();
            rx.recv().await;
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(CHANNEL_SIZE)
}

async fn bench_channel_mpmc() -> f64 {
    let mut stats = Stats::new();
    let num_producers = 4;
    let num_consumers = 4;
    let messages_per_producer = CHANNEL_SIZE / num_producers;

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let (tx, rx) = async_channel::bounded(CHANNEL_SIZE);

        let start = Instant::now();

        // Spawn producers
        let mut producer_handles = Vec::new();
        for p in 0..num_producers {
            let tx = tx.clone();
            let handle = tokio::spawn(async move {
                for i in 0..messages_per_producer {
                    tx.send(p * messages_per_producer + i).await.unwrap();
                }
            });
            producer_handles.push(handle);
        }

        // Spawn consumers
        let counter = Arc::new(AtomicUsize::new(0));
        let mut consumer_handles = Vec::new();
        for _ in 0..num_consumers {
            let rx = rx.clone();
            let counter = counter.clone();
            let handle = tokio::spawn(async move {
                while let Ok(_msg) = rx.recv().await {
                    counter.fetch_add(1, Ordering::Relaxed);
                }
            });
            consumer_handles.push(handle);
        }

        // Wait for producers
        for handle in producer_handles {
            handle.await.unwrap();
        }

        // Close channel
        drop(tx);

        // Wait for consumers
        for handle in consumer_handles {
            handle.await.unwrap();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(CHANNEL_SIZE)
}

// ============================================================================
// Synchronization Benchmarks
// ============================================================================

async fn bench_semaphore() -> f64 {
    let sem = Arc::new(Semaphore::new(100));
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();

        for _ in 0..BENCHMARK_SIZE {
            let permit = sem.acquire().await.unwrap();
            drop(permit);
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(BENCHMARK_SIZE)
}

async fn bench_mutex_uncontended() -> f64 {
    let mutex = Arc::new(Mutex::new(0u64));
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();

        for _ in 0..BENCHMARK_SIZE {
            let mut guard = mutex.lock().await;
            *guard += 1;
            drop(guard);
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(BENCHMARK_SIZE)
}

async fn bench_mutex_contention() -> f64 {
    let num_threads = 4;
    let ops_per_thread = CHANNEL_SIZE / num_threads;  // Use smaller N for contention
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let mutex = Arc::new(Mutex::new(0u64));
        let start = Instant::now();

        let mut handles = Vec::new();
        for _ in 0..num_threads {
            let mutex = mutex.clone();
            let handle = tokio::spawn(async move {
                for _ in 0..ops_per_thread {
                    let mut guard = mutex.lock().await;
                    *guard += 1;
                    drop(guard);
                }
            });
            handles.push(handle);
        }

        for handle in handles {
            handle.await.unwrap();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(num_threads * ops_per_thread)
}

async fn bench_rwlock_read() -> f64 {
    let lock = Arc::new(RwLock::new(0u64));
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();

        for _ in 0..BENCHMARK_SIZE {
            let guard = lock.read().await;
            std::hint::black_box(*guard);
            drop(guard);
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(BENCHMARK_SIZE)
}

async fn bench_rwlock_write() -> f64 {
    let lock = Arc::new(RwLock::new(0u64));
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();

        for _ in 0..BENCHMARK_SIZE {
            let mut guard = lock.write().await;
            *guard += 1;
            drop(guard);
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(BENCHMARK_SIZE)
}

async fn bench_rwlock_contention() -> f64 {
    // Mix of readers and writers contending
    let num_readers = 4;
    let num_writers = 2;
    let ops_per_thread = CHANNEL_SIZE / (num_readers + num_writers);
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let lock = Arc::new(RwLock::new(0u64));
        let start = Instant::now();

        let mut handles = Vec::new();

        // Spawn readers
        for _ in 0..num_readers {
            let lock = lock.clone();
            let handle = tokio::spawn(async move {
                for _ in 0..ops_per_thread {
                    let guard = lock.read().await;
                    std::hint::black_box(*guard);
                    drop(guard);
                }
            });
            handles.push(handle);
        }

        // Spawn writers
        for _ in 0..num_writers {
            let lock = lock.clone();
            let handle = tokio::spawn(async move {
                for _ in 0..ops_per_thread {
                    let mut guard = lock.write().await;
                    *guard += 1;
                    drop(guard);
                }
            });
            handles.push(handle);
        }

        for handle in handles {
            handle.await.unwrap();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op((num_readers + num_writers) * ops_per_thread)
}

async fn bench_semaphore_contention() -> f64 {
    let num_threads = 8;
    let permits = 2;
    let ops_per_thread = CHANNEL_SIZE / num_threads;
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let sem = Arc::new(Semaphore::new(permits));
        let start = Instant::now();

        let mut handles = Vec::new();
        for _ in 0..num_threads {
            let sem = sem.clone();
            let handle = tokio::spawn(async move {
                for _ in 0..ops_per_thread {
                    let permit = sem.acquire().await.unwrap();
                    std::hint::black_box(&permit);
                    drop(permit);
                }
            });
            handles.push(handle);
        }

        for handle in handles {
            handle.await.unwrap();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(num_threads * ops_per_thread)
}

async fn bench_barrier() -> f64 {
    let num_threads = 4;
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let barrier = Arc::new(Barrier::new(num_threads));
        let start = Instant::now();

        let mut handles = Vec::new();
        for _ in 0..num_threads {
            let barrier = barrier.clone();
            let handle = tokio::spawn(async move {
                barrier.wait().await;
            });
            handles.push(handle);
        }

        for handle in handles {
            handle.await.unwrap();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    // Total time for one barrier synchronization
    stats.avg_ns() as f64
}

async fn bench_parker() -> f64 {
    // Use thread::park/unpark for comparison (std parking)
    // Tokio doesn't have a direct equivalent, so we use Notify for single-thread wake
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();

        for _ in 0..BENCHMARK_SIZE {
            let notify = Notify::new();
            // Immediately notify (no waiter) - measures notify overhead
            notify.notify_one();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(BENCHMARK_SIZE)
}

async fn bench_notify() -> f64 {
    let num_threads = 4;
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let notify = Arc::new(Notify::new());
        let woken = Arc::new(AtomicUsize::new(0));
        let start = Instant::now();

        let mut handles = Vec::new();
        for _ in 0..num_threads {
            let notify = notify.clone();
            let woken = woken.clone();
            let handle = tokio::spawn(async move {
                notify.notified().await;
                woken.fetch_add(1, Ordering::Relaxed);
            });
            handles.push(handle);
        }

        // Give threads time to enter wait
        tokio::time::sleep(Duration::from_micros(100)).await;

        // Wake all
        notify.notify_waiters();

        for handle in handles {
            handle.await.unwrap();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    // Total time for notify_waiters
    stats.avg_ns() as f64
}

async fn bench_oneshot() -> f64 {
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();

        for i in 0..BENCHMARK_SIZE {
            let (tx, rx) = oneshot::channel();
            tx.send(i).unwrap();
            let _ = rx.await.unwrap();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(BENCHMARK_SIZE)
}

async fn bench_mpmc_lockfree() -> f64 {
    // async_channel is already lock-free MPMC
    // This is same as channel_mpmc but single-threaded
    let mut stats = Stats::new();

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let (tx, rx) = async_channel::bounded(CHANNEL_SIZE);
        let start = Instant::now();

        for i in 0..CHANNEL_SIZE {
            tx.send(i).await.unwrap();
        }

        for _ in 0..CHANNEL_SIZE {
            let _ = rx.recv().await.unwrap();
        }

        let elapsed = start.elapsed().as_nanos() as u64;
        if iter >= WARMUP_ITERATIONS {
            stats.add(elapsed);
        }
    }

    stats.ns_per_op(CHANNEL_SIZE)
}

// ============================================================================
// Timer Benchmarks
// ============================================================================

async fn bench_timer_precision() -> f64 {
    let mut stats = Stats::new();
    let target = Duration::from_millis(1);

    for iter in 0..(WARMUP_ITERATIONS + ITERATIONS) {
        let start = Instant::now();
        tokio::time::sleep(target).await;
        let elapsed = start.elapsed();

        if iter >= WARMUP_ITERATIONS {
            let drift = if elapsed > target {
                (elapsed - target).as_nanos() as u64
            } else {
                (target - elapsed).as_nanos() as u64
            };
            stats.add(drift);
        }
    }

    stats.avg_ns() as f64
}

// ============================================================================
// Throughput Benchmarks
// ============================================================================

async fn bench_task_throughput() -> f64 {
    let counter = Arc::new(AtomicUsize::new(0));
    let duration = Duration::from_millis(100);

    let start = Instant::now();
    let mut handles = Vec::new();

    // Spawn tasks that increment counter
    while start.elapsed() < duration {
        let counter = counter.clone();
        let handle = tokio::spawn(async move {
            counter.fetch_add(1, Ordering::Relaxed);
        });
        handles.push(handle);

        // Yield occasionally to not overwhelm
        if handles.len() % 1000 == 0 {
            tokio::task::yield_now().await;
        }
    }

    // Wait for all tasks
    for handle in handles {
        let _ = handle.await;
    }

    let total_tasks = counter.load(Ordering::Relaxed);
    let elapsed_secs = start.elapsed().as_secs_f64();

    total_tasks as f64 / elapsed_secs
}
