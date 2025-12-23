## io_uring internals 
- [ ] Configure recv/send with zero copy (current hardware does not support it)
    - [ ] Conditionally compile ZC logic if hardware supports it
- [X] Multishot accept
- [ ] Multishot read

## Overall features
- [ ] Relay request to downstream
- [ ] Configure multiple downstreams for load balancing
- [ ] Connection pool with downstream or 1-to-1 socket?
    - Pool is harder but more efficient
    - Enqueue requests and split them up into keepalive connections
    - [ ] use direct descriptors for downstream server pool

- [ ] Map different routes to different downstreams to act as reverse proxy
    - Can it be done at a TCP level?

## Testing/Quality
- [ ] Fuzz testing somewhere ?
- [ ] Perf/Stress testing
