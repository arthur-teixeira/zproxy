## io_uring internals 
- [X] Multishot accept
- [X] Relay request to upstream
- [X] Relay response to downstream
- Improve Data representation
    - [X] split into two equal objects, one for upstream and one for downstream.
    - [X] each data entity should have a standalone state
    - [X] create objects inside an object pool and replace all pointers with indices into the pool
- [X] Configure multiple upstreams for load balancing
- [X] Ipv6 support

## Correctness
- [X] Full-duplex streaming — current flow is half-duplex (recv downstream → send upstream → recv upstream → send downstream); splice both directions simultaneously
- [ ] Fix memory leak in Uring.deinit — mmap regions (sq ring, cq ring, sqes) are never munmap'd

## Reliability
- [ ] Upstream health checks — periodic TCP probes to remove downed backends from rotation
- [ ] Failover on connect error — retry on a different upstream instead of dropping the downstream connection
- [ ] Timeouts — connect timeout, idle timeout, read/write deadline via IORING_OP_LINK_TIMEOUT

## Observability
- [ ] Structured logging — replace std.debug.print with leveled, machine-readable log output (JSON or logfmt)
- [ ] Access log — one line per connection: timestamp, client IP, upstream, bytes transferred, duration, error
- [ ] Metrics — active connections, bytes in/out, error counts, latency histograms;

## Security
- [ ] TLS termination — integrate bearssl or mbedtls to sit in front of TLS backends
- [ ] Connection rate limiting and max concurrent connections cap
- [ ] IP allowlist/denylist (basic client ACL)

## Configuration
- [ ] CLI arg for config file path (default: ./zproxy.json)
- [ ] Config hot reload on SIGHUP without dropping existing connections
- [ ] Weighted upstreams and additional LB strategies (least-connections, IP-hash for sticky sessions)

## Performance
- [X] Zero-copy forwarding with IORING_OP_SPLICE — move data between sockets through a kernel pipe, never touching userspace buffers
- [ ] O(1) free-list in Pool — replace linear scan in reserve() and ensure_free_slots() with an intrusive free-list stack
- [ ] Cache-align hot Stream fields — pack state, opposing, fd into the first cache line
- [ ] SQ polling (IORING_SETUP_SQPOLL) — dedicated kernel thread polls SQ, eliminating io_uring_enter syscalls at the cost of one spinning core
- [ ] IORING_SETUP_SINGLE_ISSUER + IORING_SETUP_COOP_TASKRUN — skip ring locking and defer task work to submit call (single-threaded safe)
- [ ] Linked SQEs (IOSQE_IO_LINK) — chain connect → send as a single submission to avoid waiting for intermediate CQEs
- [ ] Multi-core: one io_uring per thread with SO_REUSEPORT — kernel distributes accepted connections across threads with no cross-thread coordination
- [ ] TCP_NODELAY on both downstream and upstream sockets — eliminates Nagle delay on small writes
- [ ] Tune SO_SNDBUF/SO_RCVBUF — larger socket buffers reduce round-trips needed to fill the pipe on high-throughput connections
- [ ] Busy polling (SO_BUSY_POLL / IORING_SETUP_IOPOLL) — spin instead of sleep for sub-100µs latency (tradeoff: burns a CPU core)

## Benchmarking
- [ ] Echo server binary (src/bench/echo_server.zig) exposed as `zig build bench-server`
- [ ] `zig build bench` step — starts echo server, starts zproxy, runs tcpkali, saves report, tears down
- [ ] Result format: JSON file at bench/results/<git-hash>.json capturing timestamp, git hash, and metrics (throughput, connections/sec, p50/p99/p999 latency, error rate)
- [ ] Comparison script — diff two result files and surface regressions and improvements
- [ ] (future) Replace tcpkali with a native Zig load generator

## Operational
- [ ] Install SIGTERM/SIGINT handlers in main and pass the atomic bool to proxy()
- [ ] SO_REUSEPORT on the listener socket for multi-core scalability
- [ ] TCP socket tuning — TCP_NODELAY, SO_KEEPALIVE, configurable listen backlog
