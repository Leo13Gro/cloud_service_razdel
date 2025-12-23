CREATE TABLE IF NOT EXISTS jobs (
  id uuid PRIMARY KEY,
  status text NOT NULL CHECK (status IN ('queued','running','done','error')),
  payload_text text NOT NULL,
  started_at timestamptz NULL,
  finished_at timestamptz NULL,
  error text NULL
);

CREATE TABLE IF NOT EXISTS results (
  job_id uuid PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
  sentences jsonb NOT NULL,
  tokens jsonb NOT NULL
);
