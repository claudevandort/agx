/// SQL migration strings. Each entry is applied in order.
/// The migrations table tracks which have been run.
pub const migrations = [_][]const u8{
    // Migration 0: schema setup
    \\CREATE TABLE IF NOT EXISTS agx_migrations (
    \\    version INTEGER PRIMARY KEY,
    \\    applied_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS tasks (
    \\    id BLOB PRIMARY KEY,          -- 16-byte ULID
    \\    description TEXT NOT NULL,
    \\    base_commit TEXT NOT NULL,
    \\    base_branch TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'active',
    \\    resolved_exploration_id BLOB,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS explorations (
    \\    id BLOB PRIMARY KEY,
    \\    task_id BLOB NOT NULL REFERENCES tasks(id),
    \\    idx INTEGER NOT NULL,
    \\    worktree_path TEXT NOT NULL,
    \\    branch_name TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'active',
    \\    approach TEXT,
    \\    summary TEXT,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS sessions (
    \\    id BLOB PRIMARY KEY,
    \\    exploration_id BLOB NOT NULL REFERENCES explorations(id),
    \\    agent_type TEXT,
    \\    model_version TEXT,
    \\    environment_fingerprint TEXT,
    \\    initial_prompt TEXT,
    \\    exit_reason TEXT,
    \\    started_at INTEGER NOT NULL,
    \\    ended_at INTEGER
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS events (
    \\    id BLOB PRIMARY KEY,
    \\    session_id BLOB NOT NULL REFERENCES sessions(id),
    \\    kind TEXT NOT NULL,
    \\    data TEXT,
    \\    created_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS evidence (
    \\    id BLOB PRIMARY KEY,
    \\    exploration_id BLOB NOT NULL REFERENCES explorations(id),
    \\    kind TEXT NOT NULL,
    \\    status TEXT NOT NULL,
    \\    hash TEXT,
    \\    summary TEXT,
    \\    raw_path TEXT,
    \\    recorded_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS snapshots (
    \\    id BLOB PRIMARY KEY,
    \\    session_id BLOB NOT NULL REFERENCES sessions(id),
    \\    commit_sha TEXT NOT NULL,
    \\    summary TEXT,
    \\    created_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_explorations_task ON explorations(task_id);
    \\CREATE INDEX IF NOT EXISTS idx_sessions_exploration ON sessions(exploration_id);
    \\CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
    \\CREATE INDEX IF NOT EXISTS idx_evidence_exploration ON evidence(exploration_id);
    \\CREATE INDEX IF NOT EXISTS idx_snapshots_session ON snapshots(session_id);
    ,
    // Migration 1: ingest offset tracking
    \\CREATE TABLE IF NOT EXISTS ingest_offsets (
    \\    file_name TEXT PRIMARY KEY,
    \\    byte_offset INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    ,
    // Migration 2: schema constraints
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_explorations_task_idx ON explorations(task_id, idx);
    \\
    ,
    // Migration 3: FTS5 full-text search index
    \\CREATE VIRTUAL TABLE IF NOT EXISTS context_fts USING fts5(
    \\    entity_type,
    \\    entity_id UNINDEXED,
    \\    task_id UNINDEXED,
    \\    source UNINDEXED,
    \\    content,
    \\    tokenize='porter unicode61'
    \\);
    \\
    ,
    // Migration 4: Batch entity + batch_id on tasks
    \\CREATE TABLE IF NOT EXISTS batches (
    \\    id BLOB PRIMARY KEY,
    \\    description TEXT NOT NULL,
    \\    base_commit TEXT NOT NULL,
    \\    base_branch TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'active',
    \\    merge_policy TEXT NOT NULL DEFAULT 'semi',
    \\    merge_order TEXT,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
    \\ALTER TABLE tasks ADD COLUMN batch_id BLOB REFERENCES batches(id);
    \\CREATE INDEX IF NOT EXISTS idx_tasks_batch ON tasks(batch_id);
    \\
    ,
    // Migration 5: merge progress tracking for resumable batch merges
    \\ALTER TABLE batches ADD COLUMN merge_progress INTEGER NOT NULL DEFAULT 0;
    \\
    ,
};
