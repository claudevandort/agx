/// SQL migration strings. Each entry is applied in order.
/// The migrations table tracks which have been run.
pub const migrations = [_][]const u8{
    // Migration 0: schema setup
    \\CREATE TABLE IF NOT EXISTS agx_migrations (
    \\    version INTEGER PRIMARY KEY,
    \\    applied_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS dispatches (
    \\    id BLOB PRIMARY KEY,
    \\    description TEXT NOT NULL,
    \\    base_commit TEXT NOT NULL,
    \\    base_branch TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'active',
    \\    merge_policy TEXT NOT NULL DEFAULT 'semi',
    \\    merge_order TEXT,
    \\    merge_progress INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS goals (
    \\    id BLOB PRIMARY KEY,          -- 16-byte ULID
    \\    description TEXT NOT NULL,
    \\    base_commit TEXT NOT NULL,
    \\    base_branch TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'active',
    \\    resolved_task_id BLOB,
    \\    dispatch_id BLOB REFERENCES dispatches(id),
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS tasks (
    \\    id BLOB PRIMARY KEY,
    \\    goal_id BLOB NOT NULL REFERENCES goals(id),
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
    \\    task_id BLOB NOT NULL REFERENCES tasks(id),
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
    \\    session_id BLOB REFERENCES sessions(id),
    \\    goal_id BLOB REFERENCES goals(id),
    \\    kind TEXT NOT NULL,
    \\    data TEXT,
    \\    created_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS evidence (
    \\    id BLOB PRIMARY KEY,
    \\    task_id BLOB NOT NULL REFERENCES tasks(id),
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
    \\CREATE TABLE IF NOT EXISTS ingest_offsets (
    \\    file_name TEXT PRIMARY KEY,
    \\    byte_offset INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE VIRTUAL TABLE IF NOT EXISTS context_fts USING fts5(
    \\    entity_type,
    \\    entity_id UNINDEXED,
    \\    goal_id UNINDEXED,
    \\    source UNINDEXED,
    \\    content,
    \\    tokenize='porter unicode61'
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_tasks_goal ON tasks(goal_id);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_goal_idx ON tasks(goal_id, idx);
    \\CREATE INDEX IF NOT EXISTS idx_sessions_task ON sessions(task_id);
    \\CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
    \\CREATE INDEX IF NOT EXISTS idx_events_goal ON events(goal_id);
    \\CREATE INDEX IF NOT EXISTS idx_evidence_task ON evidence(task_id);
    \\CREATE INDEX IF NOT EXISTS idx_snapshots_session ON snapshots(session_id);
    \\CREATE INDEX IF NOT EXISTS idx_goals_dispatch ON goals(dispatch_id);
    ,
};
