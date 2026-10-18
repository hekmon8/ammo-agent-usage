# QuotaStore

P1-02 implements a private SQLite history store, hourly aggregates, bounded retention and an atomic public snapshot. A single collector lease prevents duplicate collection. Database state is authoritative and repairs the public projection after interrupted publication; corrupt or conflicting input cannot replace valid data. Tests cover competing publishers, damaged projections, history correction and retention. Only initial schema v1 is supported; unknown schema versions fail closed.
