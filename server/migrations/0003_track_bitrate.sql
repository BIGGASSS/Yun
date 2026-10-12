-- Existing tracks keep unknown bitrate; audio properties are read only on upload.
ALTER TABLE tracks ADD COLUMN bitrate_kbps INTEGER
 CHECK (bitrate_kbps IS NULL OR bitrate_kbps > 0);
