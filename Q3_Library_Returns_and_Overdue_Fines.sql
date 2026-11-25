-- =====================================================================
-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run with:  psql -d your_database -f Q3_Library_Returns_and_Overdue_Fines.sql
-- Rule: fine = K2 x (days after due date); returning ON the due date = no fine.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

CREATE TABLE books (
    book_id  SERIAL       PRIMARY KEY,
    title    VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id        SERIAL        PRIMARY KEY,
    book_id        INTEGER       NOT NULL REFERENCES books (book_id),
    borrower_name  VARCHAR(100)  NOT NULL,
    borrowed_on    DATE          NOT NULL,
    due_on         DATE          NOT NULL,
    returned_on    DATE          NULL,
    fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id          SERIAL    PRIMARY KEY,
    loan_id           INTEGER   NOT NULL REFERENCES loans (loan_id),
    old_returned_on   DATE      NULL,
    new_returned_on   DATE      NULL,
    changed_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date  DATE          PRIMARY KEY,
    overdue_count  INTEGER       NOT NULL DEFAULT 0,
    total_fine     NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Computer Networks');

-- Six loans, all inserted open; two are returned later via pr_return_loan
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Mary Zulu',     CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 1 open, OVERDUE
    (1, 'John Tembo',    CURRENT_DATE - 10, CURRENT_DATE + 4),   -- 2 open, ON TIME
    (2, 'Peter Chanda',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 3 will be returned late
    (2, 'Grace Mumba',   CURRENT_DATE - 12, CURRENT_DATE - 2),   -- 4 open, OVERDUE
    (3, 'Alice Mulenga', CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 5 open, ON TIME
    (3, 'Chola Kunda',   CURRENT_DATE - 15, CURRENT_DATE - 1);   -- 6 will be returned on due date

-- ---------------------------------------------------------------------
-- (b) Function fn_loan_fine
--     LEAST() ignores NULL, so LEAST(p_as_of, returned_on) = p_as_of for open loans.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_end := LEAST(p_as_of, v_returned);       -- a returned loan stops accumulating

    RETURN 2.00 * GREATEST(v_end - v_due, 0);  -- K2 per day, minimum zero
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure pr_return_loan (return date and final fine stored together)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;

    -- returned_on is still NULL here, so the function measures up to p_returned_on
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    -- One UPDATE stores both values together
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: log changes of returned_on (AFTER UPDATE, row level)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_loan_audit ON loans;
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)   -- NULL-safe "date changed"
EXECUTE FUNCTION trg_fn_loan_audit();

-- ---------------------------------------------------------------------
-- (e) View: v_overdue_loans
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- ---------------------------------------------------------------------
-- (f) Index: a book's UNRETURNED loans (partial index = small, only open loans)
-- ---------------------------------------------------------------------
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_overdue
--     "Overdue as of p_as_of" = not yet returned on that date AND due before it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)), 0)
    FROM loans l
    WHERE (l.returned_on IS NULL OR l.returned_on > p_as_of)
      AND l.due_on < p_as_of
    ON CONFLICT (snapshot_date)
    DO UPDATE SET overdue_count = EXCLUDED.overdue_count,
                  total_fine    = EXCLUDED.total_fine;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every day at 00:10, for CURRENT_DATE
SELECT cron.schedule(
    'library_refresh_overdue',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE)$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- Return two loans: loan 3 late (fine K4), loan 6 exactly on its due date (fine K0)
CALL pr_return_loan(3, CURRENT_DATE - 14);
CALL pr_return_loan(6, CURRENT_DATE - 1);

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;     -- exactly two rows

-- (b) Function tests
SELECT fn_loan_fine(1, CURRENT_DATE) AS open_overdue_fine,   -- 6 days x 2 = 12
       fn_loan_fine(2, CURRENT_DATE) AS on_time_fine,        -- 0
       fn_loan_fine(3, CURRENT_DATE) AS returned_late_fine;  -- stops at return date = 4
-- SELECT fn_loan_fine(99, CURRENT_DATE);   -- ERROR: Unknown loan_id

-- (c) Rejections (uncomment one at a time)
-- CALL pr_return_loan(99, CURRENT_DATE);       -- ERROR: unknown loan
-- CALL pr_return_loan(3, CURRENT_DATE);        -- ERROR: already returned
-- CALL pr_return_loan(2, CURRENT_DATE - 60);   -- ERROR: before borrowed_on

-- (d) Updating something other than returned_on creates no audit row
UPDATE loans SET borrower_name = 'John Tembo' WHERE loan_id = 2;
SELECT COUNT(*) AS audit_rows FROM loan_audit;   -- still 2

-- (e) View
SELECT * FROM v_overdue_loans ORDER BY loan_id;

-- (f) Index query and plan (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Rerun-safe snapshot
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary ORDER BY snapshot_date;   -- one row for today

SELECT jobid, jobname, schedule, command, active FROM cron.job;
