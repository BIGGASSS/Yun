#!/usr/bin/env python3
"""Synthetic SQLite-only narrow-range stats benchmark; never opens application data.

Run: python3 server/scripts/benchmark-stats.py
Includes JSON aggregation, excludes HTTP/SQLx/disk/concurrency. Not a latency SLO.
"""
import json
import pathlib
import re
import sqlite3
import statistics
import time

server = pathlib.Path(__file__).resolve().parents[1]
source = (server / "src/events.rs").read_text()
statement = re.search(r'const STATS: &str = "(.*?)";', source, re.S).group(1)
print("SQLite", sqlite3.sqlite_version)
for count in (10_000, 100_000):
    with sqlite3.connect(":memory:") as db:
        for migration in sorted((server / "migrations").glob("*.sql")):
            db.executescript(migration.read_text())
        db.execute("INSERT INTO users(id,username,password_hash) VALUES('u','bench','unused')")
        db.execute("INSERT INTO devices VALUES('u','d')")
        db.execute("INSERT INTO tracks(id,user_id,title,artist,album,album_artist,duration_ms,size_bytes,sha256,mime_type,audio_path,revision,created_at) VALUES('t','u','Track','Artist','Album','',180000,1,'hash','audio/mpeg','unused',1,0)")
        db.executemany("INSERT INTO listening_events VALUES(?,?,?,?,?,?,?,?,?)", (
            ('u', f'e{i:09d}', 'd', f's{i//18:09d}', 't', i*10000, (i+1)*10000, 10000, 0)
            for i in range(count)
        ))
        db.commit()
        parameters = ('u', (count - 10) * 10000, count * 10000)
        elapsed = []
        for _ in range(6):
            start = time.perf_counter()
            result = json.loads(db.execute(statement, parameters).fetchone()[0])
            elapsed.append((time.perf_counter() - start) * 1000)
            assert result['listened_ms'] == 100000
        plan = [row[3] for row in db.execute('EXPLAIN QUERY PLAN ' + statement, parameters)]
        assert sum('MATERIALIZE selected' in line for line in plan) == 1
        assert any('events_range' in line for line in plan)
        assert any('events_session' in line for line in plan)
        print(f'N={count} selected_events=10 median_ms={statistics.median(elapsed[1:]):.3f}')
        print('\n'.join(plan))
