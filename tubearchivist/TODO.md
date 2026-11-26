# TODO

## Experiment: lower the Elasticsearch heap to reduce memory use

Status: not started. Measurements below were taken on 2026-11-25.

### The issue

The stack uses about 2.25 GiB of memory. Before it was added back, Docker Desktop
was limited to 7.75 GiB with about 5.3 GiB in use. Termix became unresponsive
around the time this stack was started (low memory is the likely cause, not
confirmed), and the limit was raised to 16 GB.

| Container | Memory | Notes |
|---|---|---|
| `archivist-es` | 1.5 GiB | Fixed 1 GiB Java heap plus Java's own overhead |
| `tubearchivist` | 750 MiB | Web server workers, task workers and scheduler |
| `archivist-redis` | 13 MiB | Negligible |

Elasticsearch looks oversized for this library: the index was under 1 MB, and
about 320 MB of the heap was in use in a single sample (21 videos).

The [install docs](https://docs.tubearchivist.com/installation/docker-compose/)
give around 2 GB of memory for a small setup and 4 GB for a mid-to-large one. I
saw no heap guidance there, so a smaller heap is untested.

### Proposal

In `docker-compose.yml`, under `archivist-es`, change:

```yaml
      - "ES_JAVA_OPTS=-Xms1g -Xmx1g"
```

to:

```yaml
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
```

Estimated saving: about 0.5 GiB.

Leave the app container alone. Its worker counts are set in its startup scripts,
and I found no documented setting for them.

### How to test

1. Record the baseline (commands below).
2. Make the change, then run `docker compose up -d archivist-es` while no
   downloads are running.
3. Check search and browsing, download a video, run a subscription rescan, and
   run a Plex library scan.
4. Watch for a few days, including at least one scheduled download.
5. Record memory and heap use again and compare.

Memory per container:

```sh
docker stats --no-stream | grep -E 'NAME|archivist'
```

Heap use, restarts and out-of-memory kills:

```sh
docker exec archivist-es sh -c 'curl -s -u "elastic:$ELASTIC_PASSWORD" "localhost:9200/_nodes/stats/jvm?filter_path=nodes.*.jvm.mem.heap_used_in_bytes,nodes.*.jvm.mem.heap_max_in_bytes"'
docker inspect archivist-es --format 'restarts={{.RestartCount}} oom={{.State.OOMKilled}}'
docker logs --since 24h archivist-es 2>&1 | grep -E 'OutOfMemoryError|CircuitBreakingException'
```

### Revert if

Elasticsearch restarts or is killed, the logs show memory errors, or searches and
indexing fail or become noticeably slow. Restore `-Xms1g -Xmx1g` and run
`docker compose up -d archivist-es` again.
