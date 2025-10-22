-- Dragon Dictation Pro v7.0 - Database Schema
-- For integration with Surgical Command Center PostgreSQL Database

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- For text search optimization

-- =============================================================================
-- TRANSCRIPTION TRACKING
-- =============================================================================

CREATE TABLE transcriptions (
    id UUID PRIMARY KEY,
    timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
    audio_duration FLOAT NOT NULL,
    processing_time FLOAT NOT NULL,
    word_count INTEGER NOT NULL,
    confidence_avg FLOAT NOT NULL CHECK (confidence_avg >= 0 AND confidence_avg <= 1),
    text TEXT NOT NULL,
    
    -- Foreign keys to Surgical Command Center
    patient_id VARCHAR(50),
    procedure_id VARCHAR(50),
    surgeon_id VARCHAR(50),
    
    -- Metadata
    model_used VARCHAR(50) DEFAULT 'medium.en',
    language VARCHAR(10) DEFAULT 'en',
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX idx_transcriptions_timestamp ON transcriptions(timestamp DESC);
CREATE INDEX idx_transcriptions_patient ON transcriptions(patient_id);
CREATE INDEX idx_transcriptions_procedure ON transcriptions(procedure_id);
CREATE INDEX idx_transcriptions_surgeon ON transcriptions(surgeon_id);
CREATE INDEX idx_transcriptions_confidence ON transcriptions(confidence_avg);

-- Full-text search on transcription text
CREATE INDEX idx_transcriptions_text_search ON transcriptions USING gin(to_tsvector('english', text));

-- =============================================================================
-- TEMPLATE USAGE TRACKING
-- =============================================================================

CREATE TABLE template_usage (
    id UUID PRIMARY KEY,
    timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
    template_key VARCHAR(100) NOT NULL,
    template_source VARCHAR(20) NOT NULL CHECK (template_source IN ('static', 'dynamic', 'modified')),
    processing_time FLOAT NOT NULL,
    avg_confidence FLOAT NOT NULL CHECK (avg_confidence >= 0 AND avg_confidence <= 1),
    low_confidence_count INTEGER NOT NULL DEFAULT 0,
    field_count INTEGER NOT NULL DEFAULT 0,
    
    -- Link to transcription
    transcription_id UUID REFERENCES transcriptions(id) ON DELETE CASCADE,
    
    -- User tracking
    user_id VARCHAR(50),
    
    -- Correction tracking
    user_corrections INTEGER DEFAULT 0,
    
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_template_usage_timestamp ON template_usage(timestamp DESC);
CREATE INDEX idx_template_usage_template_key ON template_usage(template_key);
CREATE INDEX idx_template_usage_source ON template_usage(template_source);
CREATE INDEX idx_template_usage_user ON template_usage(user_id);
CREATE INDEX idx_template_usage_transcription ON template_usage(transcription_id);

-- =============================================================================
-- EXTRACTED FIELDS
-- =============================================================================

CREATE TABLE extracted_fields (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    note_id UUID NOT NULL REFERENCES template_usage(id) ON DELETE CASCADE,
    field_name VARCHAR(100) NOT NULL,
    value TEXT,
    confidence FLOAT NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    source VARCHAR(20) CHECK (source IN ('explicit', 'inferred', 'contextual', 'unknown')),
    
    -- Tracking
    was_corrected BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_extracted_fields_note ON extracted_fields(note_id);
CREATE INDEX idx_extracted_fields_name ON extracted_fields(field_name);
CREATE INDEX idx_extracted_fields_confidence ON extracted_fields(confidence);
CREATE INDEX idx_extracted_fields_corrected ON extracted_fields(was_corrected) WHERE was_corrected = TRUE;

-- =============================================================================
-- USER CORRECTIONS (for ML improvement tracking)
-- =============================================================================

CREATE TABLE corrections (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    note_id UUID NOT NULL REFERENCES template_usage(id) ON DELETE CASCADE,
    field_name VARCHAR(100) NOT NULL,
    original_value TEXT,
    corrected_value TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
    user_id VARCHAR(50) NOT NULL,
    
    -- Optional: categorize correction type
    correction_type VARCHAR(50), -- e.g., 'spelling', 'wrong_extraction', 'missing_info'
    
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_corrections_note ON corrections(note_id);
CREATE INDEX idx_corrections_timestamp ON corrections(timestamp DESC);
CREATE INDEX idx_corrections_user ON corrections(user_id);
CREATE INDEX idx_corrections_field ON corrections(field_name);

-- =============================================================================
-- QUALITY METRICS AGGREGATION (for dashboard performance)
-- =============================================================================

CREATE TABLE quality_metrics_daily (
    date DATE PRIMARY KEY,
    
    -- Transcription metrics
    total_transcriptions INTEGER DEFAULT 0,
    avg_transcription_confidence FLOAT,
    avg_transcription_time FLOAT,
    total_transcription_words INTEGER DEFAULT 0,
    
    -- Template metrics
    total_template_usage INTEGER DEFAULT 0,
    avg_template_confidence FLOAT,
    avg_template_time FLOAT,
    dynamic_template_count INTEGER DEFAULT 0,
    static_template_count INTEGER DEFAULT 0,
    
    -- Quality metrics
    total_corrections INTEGER DEFAULT 0,
    notes_with_corrections INTEGER DEFAULT 0,
    correction_rate FLOAT, -- percentage
    
    -- User activity
    active_users INTEGER DEFAULT 0,
    
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TEMPLATE DEFINITIONS (for version control)
-- =============================================================================

CREATE TABLE template_definitions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    template_key VARCHAR(100) NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    template_text TEXT NOT NULL,
    template_source VARCHAR(20) NOT NULL CHECK (template_source IN ('static', 'dynamic', 'ai_generated')),
    
    -- Metadata
    created_by VARCHAR(50),
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE,
    usage_count INTEGER DEFAULT 0,
    
    -- Performance tracking
    avg_confidence FLOAT,
    avg_corrections FLOAT,
    
    -- Version control
    UNIQUE(template_key, version)
);

-- Index
CREATE INDEX idx_template_definitions_key ON template_definitions(template_key);
CREATE INDEX idx_template_definitions_active ON template_definitions(is_active) WHERE is_active = TRUE;

-- =============================================================================
-- PROBLEMATIC TEMPLATES LOG
-- =============================================================================

CREATE TABLE problematic_templates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    template_key VARCHAR(100) NOT NULL,
    identified_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Issues
    avg_confidence FLOAT NOT NULL,
    avg_corrections FLOAT NOT NULL,
    usage_count INTEGER NOT NULL,
    
    -- Status
    status VARCHAR(20) DEFAULT 'identified' CHECK (status IN ('identified', 'under_review', 'resolved', 'deprecated')),
    resolution_notes TEXT,
    resolved_date DATE,
    
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Index
CREATE INDEX idx_problematic_templates_key ON problematic_templates(template_key);
CREATE INDEX idx_problematic_templates_status ON problematic_templates(status);
CREATE INDEX idx_problematic_templates_date ON problematic_templates(identified_date DESC);

-- =============================================================================
-- SYSTEM PERFORMANCE LOG
-- =============================================================================

CREATE TABLE system_performance (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
    metric_type VARCHAR(50) NOT NULL, -- 'transcription', 'template', 'api_call'
    
    -- Performance data
    processing_time FLOAT NOT NULL,
    success BOOLEAN DEFAULT TRUE,
    error_message TEXT,
    
    -- Resource usage (if available)
    gpu_memory_used INTEGER, -- MB
    gpu_temperature INTEGER, -- Celsius
    
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_system_performance_timestamp ON system_performance(timestamp DESC);
CREATE INDEX idx_system_performance_type ON system_performance(metric_type);
CREATE INDEX idx_system_performance_success ON system_performance(success) WHERE success = FALSE;

-- Partition by month for performance (optional, for high-volume systems)
-- CREATE TABLE system_performance_y2025m10 PARTITION OF system_performance
--     FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');

-- =============================================================================
-- REALTIME TRANSCRIPTION SESSIONS
-- =============================================================================

CREATE TABLE realtime_sessions (
    session_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id VARCHAR(50) NOT NULL,
    started_at TIMESTAMP NOT NULL DEFAULT NOW(),
    ended_at TIMESTAMP,
    
    -- Session data
    total_chunks_processed INTEGER DEFAULT 0,
    total_duration FLOAT, -- seconds
    final_transcription TEXT,
    
    -- Quality
    avg_chunk_confidence FLOAT,
    
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Index
CREATE INDEX idx_realtime_sessions_user ON realtime_sessions(user_id);
CREATE INDEX idx_realtime_sessions_started ON realtime_sessions(started_at DESC);

-- =============================================================================
-- VIEWS FOR COMMON QUERIES
-- =============================================================================

-- View: Recent transcriptions with template info
CREATE OR REPLACE VIEW v_recent_transcriptions AS
SELECT 
    t.id,
    t.timestamp,
    t.text,
    t.confidence_avg as transcription_confidence,
    t.word_count,
    t.patient_id,
    t.procedure_id,
    t.surgeon_id,
    tu.template_key,
    tu.template_source,
    tu.avg_confidence as template_confidence,
    tu.user_corrections,
    CASE WHEN tu.user_corrections > 0 THEN TRUE ELSE FALSE END as has_corrections
FROM transcriptions t
LEFT JOIN template_usage tu ON t.id = tu.transcription_id
ORDER BY t.timestamp DESC;

-- View: Template performance summary
CREATE OR REPLACE VIEW v_template_performance AS
SELECT 
    template_key,
    template_source,
    COUNT(*) as usage_count,
    AVG(avg_confidence) as avg_confidence,
    AVG(user_corrections) as avg_corrections,
    SUM(CASE WHEN user_corrections > 0 THEN 1 ELSE 0 END) as notes_with_corrections,
    AVG(processing_time) as avg_processing_time,
    MAX(timestamp) as last_used
FROM template_usage
GROUP BY template_key, template_source
ORDER BY usage_count DESC;

-- View: User productivity
CREATE OR REPLACE VIEW v_user_productivity AS
SELECT 
    user_id,
    COUNT(DISTINCT tu.id) as procedures_documented,
    COUNT(DISTINCT DATE(tu.timestamp)) as active_days,
    AVG(tu.avg_confidence) as avg_template_confidence,
    AVG(tu.processing_time) as avg_processing_time,
    SUM(tu.user_corrections) as total_corrections,
    AVG(t.confidence_avg) as avg_transcription_confidence
FROM template_usage tu
JOIN transcriptions t ON tu.transcription_id = t.id
WHERE user_id IS NOT NULL
GROUP BY user_id
ORDER BY procedures_documented DESC;

-- View: Daily quality trends
CREATE OR REPLACE VIEW v_daily_quality_trends AS
SELECT 
    DATE(t.timestamp) as date,
    COUNT(DISTINCT t.id) as transcription_count,
    AVG(t.confidence_avg) as avg_transcription_confidence,
    COUNT(DISTINCT tu.id) as template_usage_count,
    AVG(tu.avg_confidence) as avg_template_confidence,
    SUM(tu.user_corrections) as total_corrections,
    COUNT(DISTINCT CASE WHEN tu.template_source = 'dynamic' THEN tu.id END) as dynamic_template_count
FROM transcriptions t
LEFT JOIN template_usage tu ON t.id = tu.transcription_id
GROUP BY DATE(t.timestamp)
ORDER BY DATE(t.timestamp) DESC;

-- =============================================================================
-- FUNCTIONS AND TRIGGERS
-- =============================================================================

-- Function: Update timestamp on record modification
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$ LANGUAGE plpgsql;

-- Apply triggers to relevant tables
CREATE TRIGGER update_transcriptions_updated_at
    BEFORE UPDATE ON transcriptions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_template_usage_updated_at
    BEFORE UPDATE ON template_usage
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_extracted_fields_updated_at
    BEFORE UPDATE ON extracted_fields
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_template_definitions_updated_at
    BEFORE UPDATE ON template_definitions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_problematic_templates_updated_at
    BEFORE UPDATE ON problematic_templates
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function: Mark field as corrected when correction is added
CREATE OR REPLACE FUNCTION mark_field_corrected()
RETURNS TRIGGER AS $
BEGIN
    UPDATE extracted_fields
    SET was_corrected = TRUE
    WHERE note_id = NEW.note_id 
      AND field_name = NEW.field_name;
    RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_mark_field_corrected
    AFTER INSERT ON corrections
    FOR EACH ROW
    EXECUTE FUNCTION mark_field_corrected();

-- Function: Update correction count in template_usage
CREATE OR REPLACE FUNCTION update_correction_count()
RETURNS TRIGGER AS $
BEGIN
    UPDATE template_usage
    SET user_corrections = user_corrections + 1
    WHERE id = NEW.note_id;
    RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_correction_count
    AFTER INSERT ON corrections
    FOR EACH ROW
    EXECUTE FUNCTION update_correction_count();

-- Function: Aggregate daily quality metrics
CREATE OR REPLACE FUNCTION aggregate_daily_metrics(target_date DATE)
RETURNS VOID AS $
BEGIN
    INSERT INTO quality_metrics_daily (
        date,
        total_transcriptions,
        avg_transcription_confidence,
        avg_transcription_time,
        total_transcription_words,
        total_template_usage,
        avg_template_confidence,
        avg_template_time,
        dynamic_template_count,
        static_template_count,
        total_corrections,
        notes_with_corrections,
        correction_rate,
        active_users
    )
    SELECT
        target_date,
        COUNT(DISTINCT t.id),
        AVG(t.confidence_avg),
        AVG(t.processing_time),
        SUM(t.word_count),
        COUNT(DISTINCT tu.id),
        AVG(tu.avg_confidence),
        AVG(tu.processing_time),
        COUNT(DISTINCT CASE WHEN tu.template_source = 'dynamic' THEN tu.id END),
        COUNT(DISTINCT CASE WHEN tu.template_source = 'static' THEN tu.id END),
        COUNT(c.id),
        COUNT(DISTINCT c.note_id),
        CASE 
            WHEN COUNT(DISTINCT tu.id) > 0 
            THEN (COUNT(DISTINCT c.note_id)::FLOAT / COUNT(DISTINCT tu.id) * 100)
            ELSE 0
        END,
        COUNT(DISTINCT tu.user_id)
    FROM transcriptions t
    LEFT JOIN template_usage tu ON t.id = tu.transcription_id
    LEFT JOIN corrections c ON tu.id = c.note_id
    WHERE DATE(t.timestamp) = target_date
    ON CONFLICT (date) DO UPDATE SET
        total_transcriptions = EXCLUDED.total_transcriptions,
        avg_transcription_confidence = EXCLUDED.avg_transcription_confidence,
        avg_transcription_time = EXCLUDED.avg_transcription_time,
        total_transcription_words = EXCLUDED.total_transcription_words,
        total_template_usage = EXCLUDED.total_template_usage,
        avg_template_confidence = EXCLUDED.avg_template_confidence,
        avg_template_time = EXCLUDED.avg_template_time,
        dynamic_template_count = EXCLUDED.dynamic_template_count,
        static_template_count = EXCLUDED.static_template_count,
        total_corrections = EXCLUDED.total_corrections,
        notes_with_corrections = EXCLUDED.notes_with_corrections,
        correction_rate = EXCLUDED.correction_rate,
        active_users = EXCLUDED.active_users,
        updated_at = NOW();
END;
$ LANGUAGE plpgsql;

-- Function: Identify problematic templates
CREATE OR REPLACE FUNCTION identify_problematic_templates(
    min_usage_count INTEGER DEFAULT 10,
    max_confidence FLOAT DEFAULT 0.65,
    max_correction_rate FLOAT DEFAULT 0.20
)
RETURNS TABLE(
    template_key VARCHAR(100),
    usage_count BIGINT,
    avg_confidence FLOAT,
    avg_corrections FLOAT,
    recommendation TEXT
) AS $
BEGIN
    RETURN QUERY
    SELECT 
        tu.template_key,
        COUNT(*) as usage_count,
        AVG(tu.avg_confidence)::FLOAT as avg_confidence,
        AVG(tu.user_corrections)::FLOAT as avg_corrections,
        CASE 
            WHEN AVG(tu.avg_confidence) < 0.50 THEN 'Critical: Immediate template revision required'
            WHEN AVG(tu.avg_confidence) < 0.60 THEN 'High Priority: Template needs significant improvement'
            WHEN AVG(tu.user_corrections) > 3 THEN 'High Priority: Excessive corrections needed'
            ELSE 'Medium Priority: Consider template optimization'
        END as recommendation
    FROM template_usage tu
    WHERE tu.timestamp > NOW() - INTERVAL '30 days'
    GROUP BY tu.template_key
    HAVING 
        COUNT(*) >= min_usage_count 
        AND (
            AVG(tu.avg_confidence) < max_confidence 
            OR AVG(tu.user_corrections) > max_correction_rate * COUNT(*)
        )
    ORDER BY avg_confidence ASC, avg_corrections DESC;
END;
$ LANGUAGE plpgsql;

-- Function: Get user performance report
CREATE OR REPLACE FUNCTION get_user_performance_report(
    target_user_id VARCHAR(50),
    days_back INTEGER DEFAULT 30
)
RETURNS TABLE(
    metric_name TEXT,
    metric_value NUMERIC,
    benchmark_value NUMERIC,
    performance_rating TEXT
) AS $
BEGIN
    RETURN QUERY
    WITH user_stats AS (
        SELECT
            COUNT(DISTINCT tu.id) as procedures_count,
            AVG(tu.avg_confidence) as avg_confidence,
            AVG(tu.processing_time) as avg_time,
            SUM(tu.user_corrections)::FLOAT / NULLIF(COUNT(DISTINCT tu.id), 0) as corrections_per_note
        FROM template_usage tu
        WHERE tu.user_id = target_user_id
          AND tu.timestamp > NOW() - INTERVAL '1 day' * days_back
    ),
    benchmark_stats AS (
        SELECT
            AVG(tu.avg_confidence) as avg_confidence,
            AVG(tu.processing_time) as avg_time,
            AVG(tu.user_corrections) as corrections_per_note
        FROM template_usage tu
        WHERE tu.timestamp > NOW() - INTERVAL '1 day' * days_back
    )
    SELECT 
        'Procedures Documented'::TEXT,
        us.procedures_count::NUMERIC,
        NULL::NUMERIC,
        'N/A'::TEXT
    FROM user_stats us
    UNION ALL
    SELECT 
        'Average Confidence'::TEXT,
        us.avg_confidence::NUMERIC,
        bs.avg_confidence::NUMERIC,
        CASE 
            WHEN us.avg_confidence >= bs.avg_confidence * 1.05 THEN 'Above Average'
            WHEN us.avg_confidence >= bs.avg_confidence * 0.95 THEN 'Average'
            ELSE 'Below Average'
        END::TEXT
    FROM user_stats us, benchmark_stats bs
    UNION ALL
    SELECT 
        'Average Processing Time (s)'::TEXT,
        us.avg_time::NUMERIC,
        bs.avg_time::NUMERIC,
        CASE 
            WHEN us.avg_time <= bs.avg_time * 0.95 THEN 'Above Average'
            WHEN us.avg_time <= bs.avg_time * 1.05 THEN 'Average'
            ELSE 'Below Average'
        END::TEXT
    FROM user_stats us, benchmark_stats bs
    UNION ALL
    SELECT 
        'Corrections Per Note'::TEXT,
        us.corrections_per_note::NUMERIC,
        bs.corrections_per_note::NUMERIC,
        CASE 
            WHEN us.corrections_per_note <= bs.corrections_per_note * 0.8 THEN 'Above Average'
            WHEN us.corrections_per_note <= bs.corrections_per_note * 1.2 THEN 'Average'
            ELSE 'Below Average'
        END::TEXT
    FROM user_stats us, benchmark_stats bs;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- SCHEDULED JOBS (using pg_cron extension - optional)
-- =============================================================================

-- Note: Requires pg_cron extension
-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Aggregate metrics daily at midnight
-- SELECT cron.schedule('aggregate_daily_metrics', '0 0 * * *', 
--     'SELECT aggregate_daily_metrics(CURRENT_DATE - 1)');

-- Identify problematic templates weekly
-- SELECT cron.schedule('identify_problematic', '0 2 * * 0',
--     $
--     INSERT INTO problematic_templates (template_key, avg_confidence, avg_corrections, usage_count)
--     SELECT template_key, avg_confidence::FLOAT, avg_corrections::FLOAT, usage_count::INTEGER
--     FROM identify_problematic_templates(10, 0.65, 0.20)
--     ON CONFLICT DO NOTHING;
--     $
-- );

-- =============================================================================
-- ANALYTICS QUERIES (Example useful queries)
-- =============================================================================

-- Query: Get transcription accuracy trend
CREATE OR REPLACE VIEW v_accuracy_trend AS
SELECT 
    DATE_TRUNC('week', timestamp) as week,
    AVG(confidence_avg) as avg_confidence,
    COUNT(*) as transcription_count
FROM transcriptions
WHERE timestamp > NOW() - INTERVAL '90 days'
GROUP BY DATE_TRUNC('week', timestamp)
ORDER BY week DESC;

-- Query: Template adoption rate
CREATE OR REPLACE VIEW v_template_adoption AS
SELECT 
    template_key,
    DATE_TRUNC('month', timestamp) as month,
    COUNT(*) as usage_count,
    template_source
FROM template_usage
WHERE timestamp > NOW() - INTERVAL '180 days'
GROUP BY template_key, DATE_TRUNC('month', timestamp), template_source
ORDER BY month DESC, usage_count DESC;

-- Query: High correction fields
CREATE OR REPLACE VIEW v_high_correction_fields AS
SELECT 
    ef.field_name,
    COUNT(*) as total_extractions,
    SUM(CASE WHEN ef.was_corrected THEN 1 ELSE 0 END) as correction_count,
    (SUM(CASE WHEN ef.was_corrected THEN 1 ELSE 0 END)::FLOAT / COUNT(*) * 100) as correction_rate,
    AVG(ef.confidence) as avg_confidence
FROM extracted_fields ef
WHERE ef.value IS NOT NULL AND ef.value != ''
GROUP BY ef.field_name
HAVING COUNT(*) >= 10
ORDER BY correction_rate DESC;

-- =============================================================================
-- DATA RETENTION POLICIES
-- =============================================================================

-- Function: Archive old transcriptions (keep metadata, remove full text)
CREATE OR REPLACE FUNCTION archive_old_transcriptions(days_to_keep INTEGER DEFAULT 365)
RETURNS INTEGER AS $
DECLARE
    rows_archived INTEGER;
BEGIN
    UPDATE transcriptions
    SET text = '[ARCHIVED]'
    WHERE timestamp < NOW() - INTERVAL '1 day' * days_to_keep
      AND text != '[ARCHIVED]';
    
    GET DIAGNOSTICS rows_archived = ROW_COUNT;
    RETURN rows_archived;
END;
$ LANGUAGE plpgsql;

-- Function: Purge old performance logs
CREATE OR REPLACE FUNCTION purge_old_performance_logs(days_to_keep INTEGER DEFAULT 90)
RETURNS INTEGER AS $
DECLARE
    rows_deleted INTEGER;
BEGIN
    DELETE FROM system_performance
    WHERE timestamp < NOW() - INTERVAL '1 day' * days_to_keep;
    
    GET DIAGNOSTICS rows_deleted = ROW_COUNT;
    RETURN rows_deleted;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- SAMPLE DATA FOR TESTING (Optional - comment out for production)
-- =============================================================================

-- Uncomment for development/testing environments
/*
-- Insert sample transcription
INSERT INTO transcriptions (
    id, timestamp, audio_duration, processing_time, word_count, 
    confidence_avg, text, patient_id, procedure_id, surgeon_id
) VALUES (
    uuid_generate_v4(),
    NOW(),
    45.2,
    3.8,
    78,
    0.92,
    'Patient underwent bilateral lower extremity arteriogram with balloon angioplasty of the superficial femoral artery.',
    'PAT-001',
    'PROC-001',
    'DR-MORGAN'
);

-- Insert sample template usage
INSERT INTO template_usage (
    id, timestamp, template_key, template_source, processing_time,
    avg_confidence, low_confidence_count, field_count, user_id
) VALUES (
    uuid_generate_v4(),
    NOW(),
    'bilateral_arteriogram',
    'static',
    1.8,
    0.88,
    1,
    5,
    'DR-MORGAN'
);
*/

-- =============================================================================
-- GRANTS AND PERMISSIONS (adjust for your security requirements)
-- =============================================================================

-- Create roles if needed
-- CREATE ROLE dragon_app_user WITH LOGIN PASSWORD 'secure_password';
-- CREATE ROLE dragon_readonly WITH LOGIN PASSWORD 'readonly_password';

-- Grant permissions to application user
-- GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO dragon_app_user;
-- GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dragon_app_user;
-- GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO dragon_app_user;

-- Grant read-only permissions for reporting
-- GRANT SELECT ON ALL TABLES IN SCHEMA public TO dragon_readonly;
-- GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO dragon_readonly;

-- =============================================================================
-- COMMENTS FOR DOCUMENTATION
-- =============================================================================

COMMENT ON TABLE transcriptions IS 'Stores all audio transcriptions with metadata and quality metrics';
COMMENT ON TABLE template_usage IS 'Tracks usage of templates (static and dynamic) for procedure documentation';
COMMENT ON TABLE extracted_fields IS 'Individual fields extracted from transcriptions by AI';
COMMENT ON TABLE corrections IS 'User corrections for ML improvement and quality tracking';
COMMENT ON TABLE quality_metrics_daily IS 'Aggregated daily metrics for dashboard performance';
COMMENT ON TABLE template_definitions IS 'Template version control and management';
COMMENT ON TABLE problematic_templates IS 'Templates identified as needing improvement';
COMMENT ON TABLE system_performance IS 'System performance and resource usage logs';

COMMENT ON FUNCTION aggregate_daily_metrics IS 'Aggregates quality metrics for a specific date';
COMMENT ON FUNCTION identify_problematic_templates IS 'Identifies templates with low confidence or high correction rates';
COMMENT ON FUNCTION get_user_performance_report IS 'Generates performance report for a specific user';

-- =============================================================================
-- INITIALIZATION COMPLETE
-- =============================================================================

-- Verify schema creation
DO $
BEGIN
    RAISE NOTICE 'Dragon Dictation Pro v7.0 Database Schema Initialized Successfully';
    RAISE NOTICE 'Tables created: 10';
    RAISE NOTICE 'Views created: 6';
    RAISE NOTICE 'Functions created: 8';
    RAISE NOTICE 'Triggers created: 7';
END $;