## io_uring internals 
- [ ] Configure recv/send with zero copy (current hardware does not support it)
    - [ ] Conditionally compile ZC logic if hardware supports it
- [X] Multishot accept
- [ ] Multishot recv
    - Must configure a buffer pool with IORING_OP_PROVIDE_BUFFERS
    - Should provide a distinct buffer group to each connection
    - Each recv should write to a different buffer inside its group

- [X] Relay request to upstream
- [X] Relay response to downstream
- [ ] Improve Data representation
    - [ ] split into two equal objects, one for upstream and one for downstream. Once pipe is estabilished, make one point to the other.
    - [ ] each data entity should have a standalone state
- [ ] Configure multiple upstreams for load balancing
- [ ] Connection pool with upstream or 1-to-1 socket?
    - Pool is harder but more efficient
    - Enqueue requests and split them up into keepalive connections
    - [ ] use direct descriptors for upstream server pool
- [ ] Map different routes to different upstreams to act as reverse proxy
    - Can it be done at a TCP level?

## Testing/Quality
- [ ] Fuzz testing somewhere ?
- [ ] Perf/Stress testing

