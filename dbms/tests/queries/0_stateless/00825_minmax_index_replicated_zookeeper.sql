DROP TABLE IF EXISTS test.minmax_idx1;
DROP TABLE IF EXISTS test.minmax_idx2;

CREATE TABLE test.minmax_idx1
(
    u64 UInt64,
    i32 Int32,
    f64 Float64,
    d Decimal(10, 2),
    s String,
    e Enum8('a' = 1, 'b' = 2, 'c' = 3),
    dt Date,
    INDEX
      idx_all (i32, i32 + f64, d, s, e, dt) TYPE minmax GRANULARITY 2,
    INDEX
      idx_2 (u64 + toYear(dt), substring(s, 2, 4)) TYPE minmax GRANULARITY 3
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/test/minmax', 'r1')
ORDER BY u64
SETTINGS index_granularity = 2;

CREATE TABLE test.minmax_idx2
(
    u64 UInt64,
    i32 Int32,
    f64 Float64,
    d Decimal(10, 2),
    s String,
    e Enum8('a' = 1, 'b' = 2, 'c' = 3),
    dt Date,
    INDEX
      idx_all (i32, i32 + f64, d, s, e, dt) TYPE minmax GRANULARITY 2,
    INDEX
      idx_2 (u64 + toYear(dt), substring(s, 2, 4)) TYPE minmax GRANULARITY 3
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/test/minmax', 'r2')
ORDER BY u64
SETTINGS index_granularity = 2;


/* many small inserts => table will make merges */
INSERT INTO test.minmax_idx1 VALUES (1, 2, 4.5, 2.5, 'abc', 'a', '2014-01-01');
INSERT INTO test.minmax_idx1 VALUES (0, 5, 4.7, 6.5, 'cba', 'b', '2014-01-04');
INSERT INTO test.minmax_idx2 VALUES (1, 5, 6.9, 1.57, 'bac', 'c', '2017-01-01');
INSERT INTO test.minmax_idx2 VALUES (1, 2, 4.5, 2.5, 'abc', 'a', '2016-01-01');
INSERT INTO test.minmax_idx2 VALUES (2, 5, 4.7, 6.5, 'cba', 'b', '2015-01-01');
INSERT INTO test.minmax_idx1 VALUES (1, 5, 6.9, 1.57, 'bac', 'c', '2014-11-11');

SYSTEM SYNC REPLICA test.minmax_idx1;
SYSTEM SYNC REPLICA test.minmax_idx2;

INSERT INTO test.minmax_idx1 VALUES (1, 2, 4.5, 2.5, 'abc', 'a', '2014-02-11');
INSERT INTO test.minmax_idx1 VALUES (0, 5, 4.7, 6.5, 'cba', 'b', '2014-03-11');
INSERT INTO test.minmax_idx1 VALUES (1, 5, 6.9, 1.57, 'bac', 'c', '2014-04-11');
INSERT INTO test.minmax_idx1 VALUES (1, 2, 4.5, 2.5, 'abc', 'a', '2014-05-11');
INSERT INTO test.minmax_idx2 VALUES (2, 5, 4.7, 6.5, 'cba', 'b', '2014-06-11');
INSERT INTO test.minmax_idx2 VALUES (1, 5, 6.9, 1.57, 'bac', 'c', '2014-07-11');

SYSTEM SYNC REPLICA test.minmax_idx1;
SYSTEM SYNC REPLICA test.minmax_idx2;

/* simple select */
SELECT * FROM test.minmax_idx1 WHERE i32 = 5 AND i32 + f64 < 12 AND 3 < d AND d < 7 AND (s = 'bac' OR s = 'cba') ORDER BY dt;
SELECT * FROM test.minmax_idx2 WHERE i32 = 5 AND i32 + f64 < 12 AND 3 < d AND d < 7 AND (s = 'bac' OR s = 'cba') ORDER BY dt;

/* select with hole made by primary key */
SELECT * FROM test.minmax_idx1 WHERE u64 != 1 AND e = 'b' ORDER BY dt;
SELECT * FROM test.minmax_idx2 WHERE u64 != 1 AND e = 'b' ORDER BY dt;

DROP TABLE test.minmax_idx1;
DROP TABLE test.minmax_idx2;