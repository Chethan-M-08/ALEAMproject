-- ============================================================================
--  ALEAM - Academic Lab Equipment & Attendance Manager
--  FILE: aleam.sql      Target: Oracle Database Express Edition (XE)
--  Schema: Chethan      Tool: Oracle SQL Developer
-- ----------------------------------------------------------------------------
--  This file is fully RE-RUNNABLE. It drops and rebuilds everything.
--
--  Contents
--    0. Cleanup (drop code objects + tables)
--    1. Tables          (13 locked tables + Notification, incl. Lab)
--    2. Views           (6)
--    3. Function        (attendance percentage, overall or per lab)
--    4. Triggers        (5)  <- syllabus requirement
--    5. Procedures      (5)  <- syllabus requirement
--    6. Seed data
--    7. Demo / verification queries
--
--  ORDER MATTERS: triggers are created BEFORE the seed data, so the seed
--  itself demonstrates them (checkouts flip Item_status, penalties and
--  attendance-shortage notifications are generated automatically).
--
--  Passwords: salted SHA-256, packed into the existing Password_hash column
--  as "<salt>$<hexdigest>". The hex strings below were generated with
--  hashlib.sha256((salt + password).encode('utf-8')).hexdigest() so they
--  match aleam.py's verify_password() exactly.
-- ============================================================================

SET DEFINE OFF;

-- ============================================================================
-- 0. CLEANUP  (safe to run even if the objects do not exist)
-- ============================================================================
BEGIN
  FOR o IN (SELECT column_value AS spec FROM TABLE(sys.odcivarchar2list(
      'VIEW:V_AVAILABLE_EQUIPMENT',
      'VIEW:V_ACTIVE_BORROWS',
      'VIEW:V_STUDENT_ATTENDANCE',
      'VIEW:V_UNPAID_PENALTIES',
      'VIEW:V_LAB_UTILISATION',
      'VIEW:V_STUDENT_LAB_ATTENDANCE',
      'VIEW:V_PENALTY_COLLECTIONS',
      'VIEW:V_STAFF_ACTIVITY',
      'VIEW:V_LAB_SESSION_LOG',
      'TRIGGER:TRG_BORROW_BEFORE_INSERT',
      'TRIGGER:TRG_BORROW_AFTER_INSERT',
      'TRIGGER:TRG_BORROW_RETURN',
      'TRIGGER:TRG_PENALTY_NOTIFY',
      'TRIGGER:TRG_ATTENDANCE_SHORTAGE',
      'PROCEDURE:SP_CHECKOUT_ITEM',
      'PROCEDURE:SP_RETURN_ITEM',
      'PROCEDURE:SP_LOG_ATTENDANCE',
      'PROCEDURE:SP_PAY_PENALTY',
      'PROCEDURE:SP_CHECK_OVERDUE',
      'PROCEDURE:SP_SESSION_LOGIN',
      'PROCEDURE:SP_SESSION_LOGOUT',
      'PROCEDURE:SP_SESSION_HEARTBEAT',
      'PROCEDURE:SP_REPORT_INTERVAL',
      'PROCEDURE:SP_REPORT_STAFF',
      'PROCEDURE:SP_REPORT_LAB',
      'FUNCTION:FN_ATTENDANCE_PCT'
  ))) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP ' || SUBSTR(o.spec, 1, INSTR(o.spec, ':') - 1) || ' ' ||
                        SUBSTR(o.spec, INSTR(o.spec, ':') + 1);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
/

-- Children first, so foreign keys never block the drop.
BEGIN
  FOR t IN (SELECT column_value AS tn FROM TABLE(sys.odcivarchar2list(
      'Active_Session', 'Lab_Enrollment', 'Notification', 'Borrows', 'Lab_Attendance',
      'Lab', 'Penalty', 'Qualification', 'Student_Address', 'Item_Unit', 'Student',
      'Staff', 'System_Account', 'Equipment_Model', 'Postal_Codes', 'Department'
  ))) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP TABLE ' || t.tn || ' CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
/


-- ============================================================================
-- 1. TABLES
-- ============================================================================

-- --- Independent entities -------------------------------------------------
CREATE TABLE Department (
  Department_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  Department_name VARCHAR2(100) NOT NULL UNIQUE
);

CREATE TABLE Postal_Codes (
  Pincode VARCHAR2(10) PRIMARY KEY,
  City    VARCHAR2(50) NOT NULL
);

CREATE TABLE Equipment_Model (
  Model_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  Model_name     VARCHAR2(100) NOT NULL,
  Total_quantity NUMBER DEFAULT 0
);

-- Login table. Reference_id holds Staff_id or Student_id; NULL for ADMIN.
CREATE TABLE System_Account (
  Username      VARCHAR2(50) PRIMARY KEY,
  Password_hash VARCHAR2(256) NOT NULL,
  Access_role   VARCHAR2(20) NOT NULL CHECK (Access_role IN ('STUDENT', 'STAFF', 'ADMIN')),
  Reference_id  VARCHAR2(20)
);

-- --- Dependent on Department ----------------------------------------------
CREATE TABLE Staff (
  Staff_id      VARCHAR2(20) PRIMARY KEY,
  Staff_name    VARCHAR2(100) NOT NULL,
  Role          VARCHAR2(50),
  Department_id NUMBER REFERENCES Department(Department_id)
);

CREATE TABLE Student (
  Student_id    VARCHAR2(20) PRIMARY KEY,
  First_name    VARCHAR2(50) NOT NULL,
  Last_name     VARCHAR2(50) NOT NULL,
  DOB           DATE,
  Email         VARCHAR2(100) UNIQUE,
  Department_id NUMBER REFERENCES Department(Department_id)
);

-- A lab session runs in one of these. Department_id says whose lab it is;
-- Staff_id is the lab in-charge (distinct from whoever records a session,
-- which is Lab_Attendance.Staff_id - so neither is derivable from the other
-- and 3NF holds).
CREATE TABLE Lab (
  Lab_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  Lab_name      VARCHAR2(100) NOT NULL UNIQUE,
  Course_code   VARCHAR2(20)  NOT NULL UNIQUE,
  Department_id NUMBER REFERENCES Department(Department_id),
  Staff_id      VARCHAR2(20) REFERENCES Staff(Staff_id)
);

-- --- Weak entities / multi-valued attributes ------------------------------
-- Weak: a unit exists only as a physical instance of a model.
-- NOTE: the barcode is unique only WITHIN a model, never globally.
CREATE TABLE Item_Unit (
  Model_id     NUMBER REFERENCES Equipment_Model(Model_id),
  Unit_barcode VARCHAR2(50),
  Condition    VARCHAR2(100) DEFAULT 'Good',
  Item_status  VARCHAR2(20) DEFAULT 'Available'
               CHECK (Item_status IN ('Available', 'Checked Out', 'Under Repair', 'Retired')),
  PRIMARY KEY (Model_id, Unit_barcode)
);

-- Composite attribute: a student has a Permanent AND a Resident address.
CREATE TABLE Student_Address (
  Student_id   VARCHAR2(20) REFERENCES Student(Student_id),
  Address_type VARCHAR2(20) CHECK (Address_type IN ('Permanent', 'Resident')),
  Street       VARCHAR2(150),
  Pincode      VARCHAR2(10) REFERENCES Postal_Codes(Pincode),
  PRIMARY KEY (Student_id, Address_type)
);

-- Multi-valued attribute: a staff member has many qualifications.
CREATE TABLE Qualification (
  Staff_id      VARCHAR2(20) REFERENCES Staff(Staff_id),
  Qualifications VARCHAR2(100),
  PRIMARY KEY (Staff_id, Qualifications)
);

-- Weak: a penalty exists only in the context of a student.
CREATE TABLE Penalty (
  Student_id     VARCHAR2(20) REFERENCES Student(Student_id),
  Penalty_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  Amount         NUMBER(10,2) NOT NULL CHECK (Amount > 0),
  Payment_status VARCHAR2(20) DEFAULT 'Unpaid' CHECK (Payment_status IN ('Unpaid', 'Paid')),
  PRIMARY KEY (Student_id, Penalty_id)
);

-- --- Bridge / operational tables ------------------------------------------
-- ATTENDS_LAB: Student <-> Lab on a given date, recorded by a Staff member.
-- One row per student per lab per day, which is what the primary key says.
CREATE TABLE Lab_Attendance (
  Student_id   VARCHAR2(20) REFERENCES Student(Student_id),
  Lab_id       NUMBER NOT NULL REFERENCES Lab(Lab_id),
  Staff_id     VARCHAR2(20) REFERENCES Staff(Staff_id),   -- who recorded it
  Session_date DATE NOT NULL,
  Status       VARCHAR2(20) CHECK (Status IN ('Present', 'Absent')),
  PRIMARY KEY (Student_id, Lab_id, Session_date)
);

-- Ternary BORROWS: Student + Item_Unit + authorising Staff.
CREATE TABLE Borrows (
  Student_id    VARCHAR2(20) REFERENCES Student(Student_id),
  Model_id      NUMBER,
  Unit_barcode  VARCHAR2(50),
  Checkout_date DATE DEFAULT SYSDATE NOT NULL,
  Due_date      DATE NOT NULL,
  Return_date   DATE,
  Staff_id      VARCHAR2(20) REFERENCES Staff(Staff_id),
  PRIMARY KEY (Student_id, Model_id, Unit_barcode, Checkout_date),
  FOREIGN KEY (Model_id, Unit_barcode) REFERENCES Item_Unit(Model_id, Unit_barcode)
);

-- --- EXTENSION for the notification requirement ---------------------------
-- Rows are written by triggers, never by hand.
-- Recipient_id is a Student_id / Staff_id; NULL means "broadcast to everyone
-- holding Recipient_type" (used for ADMIN-level alerts).
CREATE TABLE Notification (
  Notification_id   NUMBER GENERATED ALWAYS AS IDENTITY,
  Recipient_type    VARCHAR2(20) NOT NULL CHECK (Recipient_type IN ('STUDENT', 'STAFF', 'ADMIN')),
  Recipient_id      VARCHAR2(20),
  Notification_type VARCHAR2(30) NOT NULL
                    CHECK (Notification_type IN ('ATTENDANCE_SHORTAGE', 'PENALTY_DUE', 'OVERDUE_RETURN', 'GENERAL')),
  Message           VARCHAR2(400) NOT NULL,
  Created_date      DATE DEFAULT SYSDATE NOT NULL,
  Is_read           CHAR(1) DEFAULT 'N' NOT NULL CHECK (Is_read IN ('Y', 'N')),
  -- Set only by the attendance trigger, so a shortage alert can be de-duplicated
  -- and retracted per lab. NULL for penalty/overdue/general notifications.
  Lab_id            NUMBER REFERENCES Lab(Lab_id),
  CONSTRAINT pk_notification PRIMARY KEY (Notification_id)
);

CREATE INDEX idx_notification_recipient ON Notification (Recipient_type, Recipient_id, Is_read);

-- ============================================================================
-- 1.1  EXTENSIONS: concurrent-login lock, report data, lab enrolment
-- ============================================================================

-- One row per logged-in account. The PRIMARY KEY on Username is the lock: a
-- second INSERT for the same user fails, even from another window or process.
-- Last_seen is refreshed by the app's heartbeat so a crashed window can be
-- recognised as stale. ON DELETE CASCADE lets the admin delete an account that
-- still has a session row.
CREATE TABLE Active_Session (
  Username   VARCHAR2(50) PRIMARY KEY
             REFERENCES System_Account(Username) ON DELETE CASCADE,
  Login_time DATE DEFAULT SYSDATE NOT NULL,
  Last_seen  DATE DEFAULT SYSDATE NOT NULL
);

-- Which students are enrolled in which lab (M:N), independent of attendance.
CREATE TABLE Lab_Enrollment (
  Student_id VARCHAR2(20) REFERENCES Student(Student_id),
  Lab_id     NUMBER       REFERENCES Lab(Lab_id),
  PRIMARY KEY (Student_id, Lab_id)
);

-- Who collected a penalty and when (needed for date-range and per-staff reports).
ALTER TABLE Penalty ADD (
  Paid_date    DATE,
  Collected_by VARCHAR2(20) CONSTRAINT fk_penalty_collected_by REFERENCES Staff(Staff_id)
);

-- Optional link from a checkout to the lab it was issued for (nullable, so
-- existing checkouts and the current seed rows stay valid).
ALTER TABLE Borrows ADD (
  Lab_id NUMBER CONSTRAINT fk_borrows_lab REFERENCES Lab(Lab_id)
);


-- ============================================================================
-- 2. VIEWS
-- ============================================================================

CREATE OR REPLACE VIEW v_available_equipment AS
SELECT m.Model_id,
       m.Model_name,
       u.Unit_barcode,
       u.Condition      AS Item_condition,
       u.Item_status
FROM Item_Unit u
JOIN Equipment_Model m ON u.Model_id = m.Model_id
WHERE u.Item_status = 'Available';

CREATE OR REPLACE VIEW v_active_borrows AS
SELECT b.Student_id,
       s.First_name || ' ' || s.Last_name AS Student_name,
       b.Model_id,
       m.Model_name,
       b.Unit_barcode,
       b.Checkout_date,
       b.Due_date,
       TRUNC(SYSDATE) - TRUNC(b.Due_date) AS Days_overdue,
       CASE WHEN TRUNC(b.Due_date) < TRUNC(SYSDATE) THEN 'OVERDUE' ELSE 'ON TIME' END AS Due_status
FROM Borrows b
JOIN Student s         ON b.Student_id = s.Student_id
JOIN Equipment_Model m ON b.Model_id   = m.Model_id
WHERE b.Return_date IS NULL;

CREATE OR REPLACE VIEW v_student_attendance AS
SELECT s.Student_id,
       s.First_name || ' ' || s.Last_name AS Student_name,
       COUNT(a.Session_date) AS Total_sessions,
       COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) AS Present_count,
       COUNT(CASE WHEN a.Status = 'Absent'  THEN 1 END) AS Absent_count,
       CASE WHEN COUNT(a.Session_date) = 0 THEN 100
            ELSE ROUND(COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) * 100
                       / COUNT(a.Session_date), 2)
       END AS Attendance_pct,
       CASE WHEN COUNT(a.Session_date) < 5 THEN 'NOT ENOUGH DATA'
            WHEN COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) * 100
                 / COUNT(a.Session_date) < 75 THEN 'SHORTAGE'
            ELSE 'OK'
       END AS Attendance_status
FROM Student s
LEFT JOIN Lab_Attendance a ON s.Student_id = a.Student_id
GROUP BY s.Student_id, s.First_name, s.Last_name;

-- Same figures as above, but broken down per lab: this is the "attendance in
-- which lab, how much" view. INNER JOIN, so a student only appears against
-- labs they actually have sessions in.
CREATE OR REPLACE VIEW v_student_lab_attendance AS
SELECT s.Student_id,
       s.First_name || ' ' || s.Last_name AS Student_name,
       l.Lab_id,
       l.Lab_name,
       l.Course_code,
       COUNT(a.Session_date) AS Total_sessions,
       COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) AS Present_count,
       COUNT(CASE WHEN a.Status = 'Absent'  THEN 1 END) AS Absent_count,
       CASE WHEN COUNT(a.Session_date) = 0 THEN 100
            ELSE ROUND(COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) * 100
                       / COUNT(a.Session_date), 2)
       END AS Attendance_pct,
       CASE WHEN COUNT(a.Session_date) < 5 THEN 'NOT ENOUGH DATA'
            WHEN COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) * 100
                 / COUNT(a.Session_date) < 75 THEN 'SHORTAGE'
            ELSE 'OK'
       END AS Attendance_status
FROM Student s
JOIN Lab_Attendance a ON a.Student_id = s.Student_id
JOIN Lab l ON l.Lab_id = a.Lab_id
GROUP BY s.Student_id, s.First_name, s.Last_name, l.Lab_id, l.Lab_name, l.Course_code;

CREATE OR REPLACE VIEW v_unpaid_penalties AS
SELECT p.Student_id,
       s.First_name || ' ' || s.Last_name AS Student_name,
       p.Penalty_id,
       p.Amount,
       p.Payment_status
FROM Penalty p
JOIN Student s ON p.Student_id = s.Student_id
WHERE p.Payment_status = 'Unpaid';

CREATE OR REPLACE VIEW v_lab_utilisation AS
SELECT m.Model_id,
       m.Model_name,
       m.Total_quantity,
       COUNT(u.Unit_barcode) AS Units_registered,
       COUNT(CASE WHEN u.Item_status = 'Available'   THEN 1 END) AS Units_available,
       COUNT(CASE WHEN u.Item_status = 'Checked Out' THEN 1 END) AS Units_out,
       COUNT(CASE WHEN u.Item_status = 'Under Repair' THEN 1 END) AS Units_repair,
       (SELECT COUNT(*) FROM Borrows b WHERE b.Model_id = m.Model_id) AS Times_borrowed
FROM Equipment_Model m
LEFT JOIN Item_Unit u ON m.Model_id = u.Model_id
GROUP BY m.Model_id, m.Model_name, m.Total_quantity;

-- Paid penalties with who collected them and when.
CREATE OR REPLACE VIEW v_penalty_collections AS
SELECT p.Penalty_id,
       p.Student_id,
       s.First_name || ' ' || s.Last_name AS Student_name,
       p.Amount,
       p.Paid_date,
       p.Collected_by,
       st.Staff_name AS Collected_by_name
FROM Penalty p
JOIN Student s    ON p.Student_id   = s.Student_id
LEFT JOIN Staff st ON p.Collected_by = st.Staff_id
WHERE p.Payment_status = 'Paid';

-- One row per staff member with their headline activity figures.
CREATE OR REPLACE VIEW v_staff_activity AS
SELECT st.Staff_id,
       st.Staff_name,
       st.Role,
       d.Department_name,
       (SELECT COUNT(*) FROM Lab l WHERE l.Staff_id = st.Staff_id)      AS Labs_supervised,
       (SELECT COUNT(*) FROM Borrows b WHERE b.Staff_id = st.Staff_id)  AS Items_issued,
       (SELECT COUNT(*) FROM Penalty p
         WHERE p.Collected_by = st.Staff_id AND p.Payment_status = 'Paid') AS Penalties_collected,
       (SELECT NVL(SUM(p.Amount), 0) FROM Penalty p
         WHERE p.Collected_by = st.Staff_id AND p.Payment_status = 'Paid') AS Dues_collected
FROM Staff st
LEFT JOIN Department d ON st.Department_id = d.Department_id;

-- One row per lab session date per recording staff member.
CREATE OR REPLACE VIEW v_lab_session_log AS
SELECT l.Lab_id,
       l.Lab_name,
       l.Course_code,
       a.Session_date,
       a.Staff_id,
       st.Staff_name,
       COUNT(*) AS Total_marked,
       COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) AS Present_count,
       COUNT(CASE WHEN a.Status = 'Absent'  THEN 1 END) AS Absent_count
FROM Lab_Attendance a
JOIN Lab   l  ON a.Lab_id   = l.Lab_id
JOIN Staff st ON a.Staff_id = st.Staff_id
GROUP BY l.Lab_id, l.Lab_name, l.Course_code, a.Session_date, a.Staff_id, st.Staff_name;


-- ============================================================================
-- 3. FUNCTION  - a student's attendance percentage
--    Returns 100 while the sample is too small to judge (< 5 sessions), so a
--    student is never flagged off a couple of records.
-- ============================================================================
-- Attendance percentage for a student. With p_lab_id left out it is the
-- overall figure across every lab; pass a lab to get that lab alone. The
-- sample-size guard applies per lab too, so a student is never flagged off a
-- single session in a lab they have barely attended.
CREATE OR REPLACE FUNCTION fn_attendance_pct (
  p_student_id VARCHAR2,
  p_lab_id     NUMBER DEFAULT NULL
) RETURN NUMBER IS
  v_total   NUMBER;
  v_present NUMBER;
BEGIN
  SELECT COUNT(*), COUNT(CASE WHEN Status = 'Present' THEN 1 END)
    INTO v_total, v_present
    FROM Lab_Attendance
   WHERE Student_id = p_student_id
     AND (p_lab_id IS NULL OR Lab_id = p_lab_id);

  IF v_total < 5 THEN
    RETURN 100;
  END IF;

  RETURN ROUND(v_present * 100 / v_total, 2);
END fn_attendance_pct;
/


-- ============================================================================
-- 4. TRIGGERS
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 4.1  BEFORE INSERT on Borrows
--      (a) defaults the loan period to 7 days when Due_date is not supplied
--      (b) refuses the checkout if the unit is not Available
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_borrow_before_insert
BEFORE INSERT ON Borrows
FOR EACH ROW
DECLARE
  v_status Item_Unit.Item_status%TYPE;
BEGIN
  IF :NEW.Due_date IS NULL THEN
    :NEW.Due_date := NVL(:NEW.Checkout_date, SYSDATE) + 7;
  END IF;

  BEGIN
    SELECT Item_status INTO v_status
      FROM Item_Unit
     WHERE Model_id = :NEW.Model_id
       AND Unit_barcode = :NEW.Unit_barcode;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20002,
        'Item ' || :NEW.Unit_barcode || ' does not exist under model ' || :NEW.Model_id || '.');
  END;

  IF v_status <> 'Available' THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Item ' || :NEW.Unit_barcode || ' cannot be issued - current status is ' || v_status || '.');
  END IF;
END trg_borrow_before_insert;
/

-- ---------------------------------------------------------------------------
-- 4.2  AFTER INSERT on Borrows
--      Moves the physical unit to 'Checked Out'. Only for loans that are
--      still open - this lets the seed load historic returned loans without
--      wrongly marking their units as out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_borrow_after_insert
AFTER INSERT ON Borrows
FOR EACH ROW
BEGIN
  IF :NEW.Return_date IS NULL THEN
    UPDATE Item_Unit
       SET Item_status = 'Checked Out'
     WHERE Model_id = :NEW.Model_id
       AND Unit_barcode = :NEW.Unit_barcode;
  END IF;
END trg_borrow_after_insert;
/

-- ---------------------------------------------------------------------------
-- 4.3  AFTER UPDATE OF Return_date on Borrows  -- the late-return engine
--      Returning the unit frees it AND, if it came back after the due date,
--      raises a penalty at Rs.5 per day late.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_borrow_return
AFTER UPDATE OF Return_date ON Borrows
FOR EACH ROW
WHEN (OLD.Return_date IS NULL AND NEW.Return_date IS NOT NULL)
DECLARE
  v_days_late NUMBER;
BEGIN
  UPDATE Item_Unit
     SET Item_status = 'Available'
   WHERE Model_id = :NEW.Model_id
     AND Unit_barcode = :NEW.Unit_barcode;

  v_days_late := TRUNC(:NEW.Return_date) - TRUNC(:NEW.Due_date);

  IF v_days_late > 0 THEN
    INSERT INTO Penalty (Student_id, Amount, Payment_status)
    VALUES (:NEW.Student_id, v_days_late * 5, 'Unpaid');
    -- trg_penalty_notify takes it from here and tells the student.
  END IF;
END trg_borrow_return;
/

-- ---------------------------------------------------------------------------
-- 4.4  AFTER INSERT on Penalty  -- tells the student they owe money
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_penalty_notify
AFTER INSERT ON Penalty
FOR EACH ROW
BEGIN
  INSERT INTO Notification (Recipient_type, Recipient_id, Notification_type, Message)
  VALUES ('STUDENT', :NEW.Student_id, 'PENALTY_DUE',
          'A penalty of Rs.' || TO_CHAR(:NEW.Amount, 'FM9999990.00') ||
          ' has been raised on your account (reference #' || :NEW.Penalty_id ||
          '). Please clear it at the lab.');
END trg_penalty_notify;
/

-- ---------------------------------------------------------------------------
-- 4.5  COMPOUND TRIGGER on Lab_Attendance  -- attendance-shortage alert
--      It must be a COMPOUND trigger: the row-level section may not query
--      Lab_Attendance (ORA-04091, mutating table). So the row-level section
--      only collects the affected (student, lab) pairs, and the
--      statement-level section - by which time the table is stable -
--      evaluates each one.
--      The 75% rule is applied PER LAB, so a student can be fine overall yet
--      short in a single subject. One unread alert per student per lab; the
--      alert is refreshed while the student stays short and retracted when
--      that lab recovers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_attendance_shortage
FOR INSERT OR UPDATE ON Lab_Attendance
COMPOUND TRIGGER

  TYPE t_sids IS TABLE OF VARCHAR2(20) INDEX BY PLS_INTEGER;
  TYPE t_lids IS TABLE OF NUMBER       INDEX BY PLS_INTEGER;
  g_sid t_sids;
  g_lid t_lids;
  g_n   PLS_INTEGER := 0;

  AFTER EACH ROW IS
  BEGIN
    g_n := g_n + 1;
    g_sid(g_n) := NVL(:NEW.Student_id, :OLD.Student_id);
    g_lid(g_n) := NVL(:NEW.Lab_id,     :OLD.Lab_id);
  END AFTER EACH ROW;

  AFTER STATEMENT IS
    v_pct     NUMBER;
    v_exists  PLS_INTEGER;
    v_sid     VARCHAR2(20);
    v_lid     NUMBER;
    v_labname VARCHAR2(100);
    v_msg     VARCHAR2(400);
  BEGIN
    FOR i IN 1 .. g_n LOOP
      v_sid := g_sid(i);
      v_lid := g_lid(i);
      v_pct := fn_attendance_pct(v_sid, v_lid);

      SELECT Lab_name INTO v_labname FROM Lab WHERE Lab_id = v_lid;

      v_msg := 'Your attendance in ' || v_labname || ' is now ' || v_pct ||
               '%, which is below the 75% requirement. Please meet your lab instructor.';

      IF v_pct < 75 THEN
        SELECT COUNT(*) INTO v_exists
          FROM Notification
         WHERE Recipient_type    = 'STUDENT'
           AND Recipient_id      = v_sid
           AND Notification_type = 'ATTENDANCE_SHORTAGE'
           AND Lab_id            = v_lid
           AND Is_read           = 'N';

        IF v_exists = 0 THEN
          INSERT INTO Notification (Recipient_type, Recipient_id, Notification_type, Lab_id, Message)
          VALUES ('STUDENT', v_sid, 'ATTENDANCE_SHORTAGE', v_lid, v_msg);
        ELSE
          -- One unread alert per student per lab is enough, but its text must
          -- not go stale: rows arrive one session at a time, so the percentage
          -- first captured when the student dipped would otherwise be frozen
          -- while the real figure keeps moving.
          UPDATE Notification SET Message = v_msg
           WHERE Recipient_type    = 'STUDENT'
             AND Recipient_id      = v_sid
             AND Notification_type = 'ATTENDANCE_SHORTAGE'
             AND Lab_id            = v_lid
             AND Is_read           = 'N';
        END IF;
      ELSE
        -- Back above the threshold for this lab: retract the alert, otherwise
        -- the student keeps being told they are short when they are not.
        DELETE FROM Notification
         WHERE Recipient_type    = 'STUDENT'
           AND Recipient_id      = v_sid
           AND Notification_type = 'ATTENDANCE_SHORTAGE'
           AND Lab_id            = v_lid
           AND Is_read           = 'N';
      END IF;
    END LOOP;
  END AFTER STATEMENT;

END trg_attendance_shortage;
/

-- ---------------------------------------------------------------------------
-- 4.6  BEFORE INSERT OR UPDATE OF Payment_status on Penalty
--      Stamps Paid_date automatically when a penalty becomes 'Paid' (unless a
--      date was supplied explicitly), and clears the payment details if a
--      penalty goes back to 'Unpaid'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_penalty_paid_stamp
BEFORE INSERT OR UPDATE OF Payment_status ON Penalty
FOR EACH ROW
BEGIN
  IF :NEW.Payment_status = 'Paid' THEN
    IF :NEW.Paid_date IS NULL THEN
      :NEW.Paid_date := SYSDATE;
    END IF;
  ELSE
    :NEW.Paid_date    := NULL;
    :NEW.Collected_by := NULL;
  END IF;
END trg_penalty_paid_stamp;
/


-- ============================================================================
-- 5. PROCEDURES
--    Every one returns (p_result, p_message) so the Python layer can show a
--    clean success/failure dialog without parsing Oracle exceptions.
--    p_result is 'OK' or 'ERROR'.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 5.1  Issue an item to a student
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_checkout_item (
  p_student_id IN  VARCHAR2,
  p_barcode    IN  VARCHAR2,
  p_staff_id   IN  VARCHAR2,
  p_lab_id     IN  NUMBER,
  p_result     OUT VARCHAR2,
  p_message    OUT VARCHAR2
) IS
  v_model_id    Item_Unit.Model_id%TYPE;
  v_status      Item_Unit.Item_status%TYPE;
  v_cnt         PLS_INTEGER;
  v_unpaid      PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM Student WHERE Student_id = p_student_id;
  IF v_cnt = 0 THEN
    p_result := 'ERROR';
    p_message := 'No student found with id ' || p_student_id || '.';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_unpaid
    FROM Penalty
   WHERE Student_id = p_student_id AND Payment_status = 'Unpaid';
  IF v_unpaid > 0 THEN
    p_result := 'ERROR';
    p_message := 'Student ' || p_student_id || ' has ' || v_unpaid ||
                 ' unpaid penalty item(s). Clear them before issuing more equipment.';
    RETURN;
  END IF;

  -- Barcodes are unique only within a model, so this must be unambiguous.
  SELECT COUNT(*) INTO v_cnt FROM Item_Unit WHERE Unit_barcode = p_barcode;
  IF v_cnt = 0 THEN
    p_result := 'ERROR';
    p_message := 'No equipment unit carries barcode ' || p_barcode || '.';
    RETURN;
  ELSIF v_cnt > 1 THEN
    p_result := 'ERROR';
    p_message := 'Barcode ' || p_barcode || ' exists under more than one model - cannot resolve it.';
    RETURN;
  END IF;

  SELECT Model_id, Item_status INTO v_model_id, v_status
    FROM Item_Unit WHERE Unit_barcode = p_barcode;

  IF v_status <> 'Available' THEN
    p_result := 'ERROR';
    p_message := 'Unit ' || p_barcode || ' is currently ' || v_status || '.';
    RETURN;
  END IF;

    IF p_lab_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_cnt FROM Lab WHERE Lab_id = p_lab_id;
    IF v_cnt = 0 THEN
      p_result := 'ERROR';
      p_message := 'No lab found with id ' || p_lab_id || '.';
      RETURN;
    END IF;
  END IF;

  INSERT INTO Borrows (Student_id, Model_id, Unit_barcode, Checkout_date, Due_date, Staff_id, Lab_id)
  VALUES (p_student_id, v_model_id, p_barcode, SYSDATE, SYSDATE + 7, p_staff_id, p_lab_id);

  p_result := 'OK';
  p_message := 'Issued ' || p_barcode || ' to ' || p_student_id || '.' || CHR(10) ||
               'Due back on ' || TO_CHAR(SYSDATE + 7, 'DD-MON-YYYY') || '.';
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_checkout_item;
/

-- ---------------------------------------------------------------------------
-- 5.2  Take an item back. The penalty, if any, is raised by trg_borrow_return.
--      (p_staff_id is kept for API symmetry: Borrows records only the issuing
--       staff member, since the locked schema has no return-staff column.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_return_item (
  p_barcode  IN  VARCHAR2,
  p_staff_id IN  VARCHAR2,
  p_result   OUT VARCHAR2,
  p_message  OUT VARCHAR2
) IS
  v_student VARCHAR2(20);
  v_due     DATE;
  v_days    NUMBER;
BEGIN
  BEGIN
    SELECT Student_id, Due_date
      INTO v_student, v_due
      FROM Borrows
     WHERE Unit_barcode = p_barcode
       AND Return_date IS NULL
       AND ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result := 'ERROR';
      p_message := 'No open checkout exists for barcode ' || p_barcode || '.';
      RETURN;
  END;

  UPDATE Borrows
     SET Return_date = SYSDATE
   WHERE Unit_barcode = p_barcode
     AND Return_date IS NULL;

  v_days := TRUNC(SYSDATE) - TRUNC(v_due);

  p_result := 'OK';
  IF v_days > 0 THEN
    p_message := 'Received ' || p_barcode || ' back from ' || v_student || '.' || CHR(10) ||
                 'It was ' || v_days || ' day(s) overdue, so a penalty of Rs.' ||
                 (v_days * 5) || ' has been raised automatically.';
  ELSE
    p_message := 'Received ' || p_barcode || ' back from ' || v_student ||
                 ' on time. No penalty.';
  END IF;
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_return_item;
/

-- ---------------------------------------------------------------------------
-- 5.3  Record attendance for today, for a named lab. The shortage alert is
--      raised by trg_attendance_shortage if this drops the student below 75%
--      in that lab.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_log_attendance (
  p_student_id IN  VARCHAR2,
  p_staff_id   IN  VARCHAR2,
  p_lab_id     IN  NUMBER,
  p_status     IN  VARCHAR2,
  p_result     OUT VARCHAR2,
  p_message    OUT VARCHAR2
) IS
  v_cnt     PLS_INTEGER;
  v_labname Lab.Lab_name%TYPE;
BEGIN
  IF p_status NOT IN ('Present', 'Absent') THEN
    p_result := 'ERROR';
    p_message := 'Status must be either Present or Absent.';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM Student WHERE Student_id = p_student_id;
  IF v_cnt = 0 THEN
    p_result := 'ERROR';
    p_message := 'No student found with id ' || p_student_id || '.';
    RETURN;
  END IF;

  BEGIN
    SELECT Lab_name INTO v_labname FROM Lab WHERE Lab_id = p_lab_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result := 'ERROR';
      p_message := 'No lab found with id ' || p_lab_id || '.';
      RETURN;
  END;

  INSERT INTO Lab_Attendance (Student_id, Lab_id, Staff_id, Session_date, Status)
  VALUES (p_student_id, p_lab_id, p_staff_id, TRUNC(SYSDATE), p_status);

  p_result := 'OK';
  p_message := 'Marked ' || p_student_id || ' ' || p_status || ' in ' || v_labname ||
               ' for ' || TO_CHAR(SYSDATE, 'DD-MON-YYYY') || '.' || CHR(10) ||
               'Attendance in ' || v_labname || ': ' ||
               fn_attendance_pct(p_student_id, p_lab_id) || '%.' || CHR(10) ||
               'Overall attendance: ' || fn_attendance_pct(p_student_id) || '%.';
  COMMIT;
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := 'Attendance for ' || p_student_id ||
                 ' in this lab is already recorded for today.';
  WHEN OTHERS THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_log_attendance;
/

-- ---------------------------------------------------------------------------
-- 5.4  Settle a penalty
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_pay_penalty (
  p_student_id IN  VARCHAR2,
  p_penalty_id IN  NUMBER,
  p_staff_id   IN  VARCHAR2,
  p_result     OUT VARCHAR2,
  p_message    OUT VARCHAR2
) IS
  v_status Penalty.Payment_status%TYPE;
  v_amount Penalty.Amount%TYPE;
BEGIN
  BEGIN
    SELECT Payment_status, Amount
      INTO v_status, v_amount
      FROM Penalty
     WHERE Student_id = p_student_id AND Penalty_id = p_penalty_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_result := 'ERROR';
      p_message := 'Penalty #' || p_penalty_id || ' does not belong to student ' || p_student_id || '.';
      RETURN;
  END;

  IF v_status = 'Paid' THEN
    p_result := 'ERROR';
    p_message := 'Penalty #' || p_penalty_id || ' has already been paid.';
    RETURN;
  END IF;

    UPDATE Penalty
     SET Payment_status = 'Paid',
         Collected_by   = p_staff_id
   WHERE Student_id = p_student_id AND Penalty_id = p_penalty_id;

  -- Close the student's matching notification so it stops nagging them.
  UPDATE Notification
     SET Is_read = 'Y'
   WHERE Recipient_type = 'STUDENT'
     AND Recipient_id   = p_student_id
     AND Notification_type = 'PENALTY_DUE'
     AND Is_read = 'N';

  p_result := 'OK';
  p_message := 'Penalty #' || p_penalty_id || ' of Rs.' ||
               TO_CHAR(v_amount, 'FM9999990.00') || ' marked as Paid.';
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_pay_penalty;
/

-- ---------------------------------------------------------------------------
-- 5.5  Overdue sweep - raises an OVERDUE_RETURN alert for every item still
--      out past its due date. Safe to call repeatedly; it will not duplicate
--      a student's alert for the same barcode on the same day.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_check_overdue (p_count OUT NUMBER) IS
BEGIN
  p_count := 0;

  FOR r IN (SELECT b.Student_id,
                   b.Unit_barcode,
                   b.Due_date,
                   TRUNC(SYSDATE) - TRUNC(b.Due_date) AS days_late
              FROM Borrows b
             WHERE b.Return_date IS NULL
               AND TRUNC(b.Due_date) < TRUNC(SYSDATE)) LOOP

    DECLARE
      v_exists PLS_INTEGER;
    BEGIN
      SELECT COUNT(*) INTO v_exists
        FROM Notification
       WHERE Recipient_type    = 'STUDENT'
         AND Recipient_id      = r.Student_id
         AND Notification_type = 'OVERDUE_RETURN'
         AND Message      LIKE '%' || r.Unit_barcode || '%'
         AND TRUNC(Created_date) = TRUNC(SYSDATE);

      IF v_exists = 0 THEN
        INSERT INTO Notification (Recipient_type, Recipient_id, Notification_type, Message)
        VALUES ('STUDENT', r.Student_id, 'OVERDUE_RETURN',
                'Item ' || r.Unit_barcode || ' was due on ' ||
                TO_CHAR(r.Due_date, 'DD-MON-YYYY') || ' and is now ' ||
                r.days_late || ' day(s) overdue. Please return it to the lab.');
        p_count := p_count + 1;
      END IF;
    END;
  END LOOP;

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_check_overdue;
/

-- ---------------------------------------------------------------------------
-- 5.6  Concurrent-login lock. The PRIMARY KEY on Active_Session.Username is
--      the lock itself; a session not refreshed for 2 minutes counts as dead.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_session_login (
  p_username IN  VARCHAR2,
  p_result   OUT VARCHAR2,
  p_message  OUT VARCHAR2
) IS
BEGIN
  DELETE FROM Active_Session
   WHERE Username = p_username
     AND Last_seen < SYSDATE - (2 / 1440);       -- stale: crashed window

  INSERT INTO Active_Session (Username) VALUES (p_username);
  COMMIT;
  p_result  := 'OK';
  p_message := 'Session started.';
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := 'This account is already logged in on another window.';
  WHEN OTHERS THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_session_login;
/

CREATE OR REPLACE PROCEDURE sp_session_logout (
  p_username IN  VARCHAR2,
  p_result   OUT VARCHAR2,
  p_message  OUT VARCHAR2
) IS
BEGIN
  DELETE FROM Active_Session WHERE Username = p_username;
  COMMIT;
  p_result  := 'OK';
  p_message := 'Session closed.';
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_session_logout;
/

-- Refreshes Last_seen. If the row vanished (e.g. the machine slept past the
-- timeout) it tries to reclaim it; ERROR means someone else now holds it.
CREATE OR REPLACE PROCEDURE sp_session_heartbeat (
  p_username IN  VARCHAR2,
  p_result   OUT VARCHAR2,
  p_message  OUT VARCHAR2
) IS
BEGIN
  UPDATE Active_Session SET Last_seen = SYSDATE WHERE Username = p_username;
  IF SQL%ROWCOUNT = 0 THEN
    INSERT INTO Active_Session (Username) VALUES (p_username);
  END IF;
  COMMIT;
  p_result  := 'OK';
  p_message := 'Heartbeat recorded.';
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := 'This account was taken over by another window.';
  WHEN OTHERS THEN
    ROLLBACK;
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_session_heartbeat;
/

-- ---------------------------------------------------------------------------
-- 5.7  REPORT A: date interval
--      Syllabus: aggregates, joins, GROUP BY, HAVING, ORDER BY, subquery in
--      SELECT, INTERSECT inside an IN-subquery, view (v_penalty_collections).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_report_interval (
  p_from            IN  DATE,
  p_to              IN  DATE,
  p_attendance      OUT SYS_REFCURSOR,
  p_lab_summary     OUT SYS_REFCURSOR,
  p_checkouts       OUT SYS_REFCURSOR,
  p_penalties       OUT SYS_REFCURSOR,
  p_totals          OUT SYS_REFCURSOR,
  p_active_students OUT SYS_REFCURSOR,
  p_result          OUT VARCHAR2,
  p_message         OUT VARCHAR2
) IS
  v_from DATE := TRUNC(p_from);
  v_to   DATE := TRUNC(p_to);
BEGIN
  IF v_from IS NULL OR v_to IS NULL THEN
    p_result := 'ERROR';
    p_message := 'Both a start date and an end date are required.';
    RETURN;
  END IF;
  IF v_from > v_to THEN
    p_result := 'ERROR';
    p_message := 'The start date must not be after the end date.';
    RETURN;
  END IF;

  OPEN p_attendance FOR
    SELECT TO_CHAR(a.Session_date, 'DD-MON-YYYY'), a.Student_id,
           s.First_name || ' ' || s.Last_name, l.Lab_name,
           NVL(st.Staff_name, '-'), a.Status
      FROM Lab_Attendance a
      JOIN Student s ON a.Student_id = s.Student_id
      JOIN Lab     l ON a.Lab_id     = l.Lab_id
      LEFT JOIN Staff st ON a.Staff_id = st.Staff_id
     WHERE TRUNC(a.Session_date) BETWEEN v_from AND v_to
     ORDER BY a.Session_date, a.Student_id;

  OPEN p_lab_summary FOR
    SELECT l.Lab_name, l.Course_code,
           COUNT(*) AS records,
           COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) AS present_cnt,
           COUNT(CASE WHEN a.Status = 'Absent'  THEN 1 END) AS absent_cnt,
           ROUND(COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) * 100 / COUNT(*), 2) AS pct
      FROM Lab_Attendance a
      JOIN Lab l ON a.Lab_id = l.Lab_id
     WHERE TRUNC(a.Session_date) BETWEEN v_from AND v_to
     GROUP BY l.Lab_id, l.Lab_name, l.Course_code
    HAVING COUNT(*) >= 2
     ORDER BY pct, l.Lab_name;

  OPEN p_checkouts FOR
    SELECT TO_CHAR(b.Checkout_date, 'DD-MON-YYYY'), b.Student_id,
           s.First_name || ' ' || s.Last_name, m.Model_name, b.Unit_barcode,
           TO_CHAR(b.Due_date, 'DD-MON-YYYY'),
           CASE WHEN b.Return_date IS NOT NULL THEN 'Returned'
                WHEN TRUNC(b.Due_date) < TRUNC(SYSDATE) THEN 'OVERDUE'
                ELSE 'On loan' END,
           NVL(st.Staff_name, '-')
      FROM Borrows b
      JOIN Student s         ON b.Student_id = s.Student_id
      JOIN Equipment_Model m ON b.Model_id   = m.Model_id
      LEFT JOIN Staff st     ON b.Staff_id   = st.Staff_id
     WHERE TRUNC(b.Checkout_date) BETWEEN v_from AND v_to
     ORDER BY b.Checkout_date, b.Student_id;

  OPEN p_penalties FOR
    SELECT pc.Penalty_id, pc.Student_id, pc.Student_name, pc.Amount,
           TO_CHAR(pc.Paid_date, 'DD-MON-YYYY'),
           NVL(pc.Collected_by_name, '-'),
           CASE WHEN pc.Amount > (SELECT AVG(Amount) FROM Penalty)
                THEN 'Above average' ELSE '-' END
      FROM v_penalty_collections pc
     WHERE TRUNC(pc.Paid_date) BETWEEN v_from AND v_to
     ORDER BY pc.Paid_date, pc.Penalty_id;

  -- FIXED: no outer aggregate mixed with scalar subqueries (was ORA-00937).
  OPEN p_totals FOR
    SELECT (SELECT COUNT(*) FROM Lab_Attendance
             WHERE TRUNC(Session_date) BETWEEN v_from AND v_to) AS att_cnt,
           (SELECT COUNT(*) FROM Borrows
             WHERE TRUNC(Checkout_date) BETWEEN v_from AND v_to) AS chk_cnt,
           (SELECT COUNT(*) FROM v_penalty_collections
             WHERE TRUNC(Paid_date) BETWEEN v_from AND v_to) AS pen_cnt,
           (SELECT NVL(SUM(Amount), 0) FROM v_penalty_collections
             WHERE TRUNC(Paid_date) BETWEEN v_from AND v_to) AS pen_amt
      FROM dual;

  OPEN p_active_students FOR
    SELECT s.Student_id, s.First_name || ' ' || s.Last_name,
           NVL(d.Department_name, '-')
      FROM Student s
      LEFT JOIN Department d ON s.Department_id = d.Department_id
     WHERE s.Student_id IN (
             SELECT Student_id FROM Lab_Attendance
              WHERE Status = 'Present'
                AND TRUNC(Session_date) BETWEEN v_from AND v_to
             INTERSECT
             SELECT Student_id FROM Borrows
              WHERE TRUNC(Checkout_date) BETWEEN v_from AND v_to)
     ORDER BY s.Student_id;

  p_result  := 'OK';
  p_message := 'Report generated.';
EXCEPTION
  WHEN OTHERS THEN
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_report_interval;
/

-- ---------------------------------------------------------------------------
-- 5.8  REPORT B: staff activity
--      Syllabus: view, subquery (share of all dues), UNION, GROUP BY + HAVING,
--      joins, aggregates, ORDER BY.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_report_staff (
  p_staff_id    IN  VARCHAR2,
  p_profile     OUT SYS_REFCURSOR,
  p_labs        OUT SYS_REFCURSOR,
  p_checkouts   OUT SYS_REFCURSOR,
  p_by_model    OUT SYS_REFCURSOR,
  p_dues        OUT SYS_REFCURSOR,
  p_result      OUT VARCHAR2,
  p_message     OUT VARCHAR2
) IS
  v_cnt PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM Staff WHERE Staff_id = p_staff_id;
  IF v_cnt = 0 THEN
    p_result := 'ERROR';
    p_message := 'No staff member found with id ' || p_staff_id || '.';
    RETURN;
  END IF;

  -- Department + headline figures from the view; subquery gives their share
  -- of all dues collected by anyone.
  OPEN p_profile FOR
    SELECT v.Staff_id, v.Staff_name, NVL(v.Role, '-'), NVL(v.Department_name, '-'),
           v.Labs_supervised, v.Items_issued, v.Penalties_collected, v.Dues_collected,
           NVL(ROUND(100 * v.Dues_collected /
               NULLIF((SELECT SUM(Amount) FROM Penalty WHERE Payment_status = 'Paid'), 0), 2), 0)
      FROM v_staff_activity v
     WHERE v.Staff_id = p_staff_id;

  -- UNION: labs they are in charge of, plus labs they recorded attendance in
  OPEN p_labs FOR
    SELECT l.Lab_id, l.Lab_name, l.Course_code
      FROM Lab l WHERE l.Staff_id = p_staff_id
    UNION
    SELECT l.Lab_id, l.Lab_name, l.Course_code
      FROM Lab l
     WHERE l.Lab_id IN (SELECT Lab_id FROM Lab_Attendance WHERE Staff_id = p_staff_id)
     ORDER BY 1;

  -- Every checkout they authorised
  OPEN p_checkouts FOR
    SELECT TO_CHAR(b.Checkout_date, 'DD-MON-YYYY'), b.Student_id,
           s.First_name || ' ' || s.Last_name, m.Model_name, b.Unit_barcode,
           NVL(l.Lab_name, '-'),
           CASE WHEN b.Return_date IS NOT NULL THEN 'Returned'
                WHEN TRUNC(b.Due_date) < TRUNC(SYSDATE) THEN 'OVERDUE'
                ELSE 'On loan' END
      FROM Borrows b
      JOIN Student s         ON b.Student_id = s.Student_id
      JOIN Equipment_Model m ON b.Model_id   = m.Model_id
      LEFT JOIN Lab l        ON b.Lab_id     = l.Lab_id
     WHERE b.Staff_id = p_staff_id
     ORDER BY b.Checkout_date DESC, b.Student_id;

  -- Checkouts per model (GROUP BY + HAVING + aggregates)
  OPEN p_by_model FOR
    SELECT m.Model_name,
           COUNT(*),
           COUNT(CASE WHEN b.Return_date IS NULL THEN 1 END),
           MIN(TO_CHAR(b.Checkout_date, 'DD-MON-YYYY'))
      FROM Borrows b
      JOIN Equipment_Model m ON b.Model_id = m.Model_id
     WHERE b.Staff_id = p_staff_id
     GROUP BY m.Model_id, m.Model_name
    HAVING COUNT(*) >= 1
     ORDER BY COUNT(*) DESC, m.Model_name;

  -- Dues collected (view)
  OPEN p_dues FOR
    SELECT pc.Penalty_id, pc.Student_id, pc.Student_name, pc.Amount,
           TO_CHAR(pc.Paid_date, 'DD-MON-YYYY')
      FROM v_penalty_collections pc
     WHERE pc.Collected_by = p_staff_id
     ORDER BY pc.Paid_date DESC, pc.Penalty_id;

  p_result  := 'OK';
  p_message := 'Report generated.';
EXCEPTION
  WHEN OTHERS THEN
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_report_staff;
/

-- ---------------------------------------------------------------------------
-- 5.9  REPORT C: lab-wise log
--      Syllabus: view, GROUP BY + HAVING, aggregates, outer joins, MINUS
--      inside an IN-subquery, ORDER BY.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_report_lab (
  p_lab_id        IN  NUMBER,
  p_sessions      OUT SYS_REFCURSOR,
  p_staff         OUT SYS_REFCURSOR,
  p_checkouts     OUT SYS_REFCURSOR,
  p_enrolled      OUT SYS_REFCURSOR,
  p_attendance    OUT SYS_REFCURSOR,
  p_never_present OUT SYS_REFCURSOR,
  p_result        OUT VARCHAR2,
  p_message       OUT VARCHAR2
) IS
  v_cnt PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM Lab WHERE Lab_id = p_lab_id;
  IF v_cnt = 0 THEN
    p_result := 'ERROR';
    p_message := 'No lab found with id ' || p_lab_id || '.';
    RETURN;
  END IF;

  OPEN p_sessions FOR
    SELECT TO_CHAR(a.Session_date, 'DD-MON-YYYY'),
           COUNT(*),
           COUNT(CASE WHEN a.Status = 'Present' THEN 1 END),
           COUNT(CASE WHEN a.Status = 'Absent'  THEN 1 END),
           ROUND(COUNT(CASE WHEN a.Status = 'Present' THEN 1 END) * 100 / COUNT(*), 2)
      FROM Lab_Attendance a
     WHERE a.Lab_id = p_lab_id
     GROUP BY a.Session_date
    HAVING COUNT(*) >= 1
     ORDER BY a.Session_date;

  OPEN p_staff FOR
    SELECT TO_CHAR(v.Session_date, 'DD-MON-YYYY'), v.Staff_id, v.Staff_name, v.Total_marked
      FROM v_lab_session_log v
     WHERE v.Lab_id = p_lab_id
     ORDER BY v.Session_date, v.Staff_id;

  OPEN p_checkouts FOR
    SELECT TO_CHAR(b.Checkout_date, 'DD-MON-YYYY'), b.Student_id,
           s.First_name || ' ' || s.Last_name, m.Model_name, b.Unit_barcode,
           NVL(st.Staff_name, '-'),
           CASE WHEN b.Return_date IS NOT NULL THEN 'Returned'
                WHEN TRUNC(b.Due_date) < TRUNC(SYSDATE) THEN 'OVERDUE'
                ELSE 'On loan' END
      FROM Borrows b
      JOIN Student s         ON b.Student_id = s.Student_id
      JOIN Equipment_Model m ON b.Model_id   = m.Model_id
      LEFT JOIN Staff st     ON b.Staff_id   = st.Staff_id
     WHERE b.Lab_id = p_lab_id
     ORDER BY b.Checkout_date, b.Student_id;

  -- Attendance is pre-aggregated per student for THIS lab only, then joined
  -- 1:1 to the enrolment row, so no row multiplication and no outer GROUP BY.
  OPEN p_enrolled FOR
    SELECT s.Student_id,
           s.First_name || ' ' || s.Last_name,
           NVL(t.total, 0),
           NVL(t.present, 0),
           CASE WHEN NVL(t.total, 0) = 0 THEN 0
                ELSE ROUND(t.present * 100 / t.total, 2) END,
           CASE WHEN NVL(t.total, 0) < 5 THEN 'NOT ENOUGH DATA'
                WHEN t.present * 100 / t.total < 75 THEN 'SHORTAGE'
                ELSE 'OK' END
      FROM Lab_Enrollment e
      JOIN Student s ON s.Student_id = e.Student_id
      LEFT JOIN (SELECT Student_id,
                        COUNT(*) AS total,
                        COUNT(CASE WHEN Status = 'Present' THEN 1 END) AS present
                   FROM Lab_Attendance
                  WHERE Lab_id = p_lab_id
                  GROUP BY Student_id) t
             ON t.Student_id = e.Student_id
     WHERE e.Lab_id = p_lab_id
     ORDER BY s.Student_id;

  OPEN p_attendance FOR
    SELECT TO_CHAR(a.Session_date, 'DD-MON-YYYY'), a.Student_id,
           s.First_name || ' ' || s.Last_name,
           NVL(st.Staff_name, '-'), a.Status
      FROM Lab_Attendance a
      JOIN Student s ON a.Student_id = s.Student_id
      LEFT JOIN Staff st ON a.Staff_id = st.Staff_id
     WHERE a.Lab_id = p_lab_id
     ORDER BY a.Session_date, a.Student_id;

  OPEN p_never_present FOR
    SELECT s.Student_id, s.First_name || ' ' || s.Last_name
      FROM Student s
     WHERE s.Student_id IN (
             SELECT Student_id FROM Lab_Enrollment WHERE Lab_id = p_lab_id
             MINUS
             SELECT Student_id FROM Lab_Attendance
              WHERE Lab_id = p_lab_id AND Status = 'Present')
     ORDER BY s.Student_id;

  p_result  := 'OK';
  p_message := 'Report generated.';
EXCEPTION
  WHEN OTHERS THEN
    p_result  := 'ERROR';
    p_message := SQLERRM;
END sp_report_lab;
/


-- ============================================================================
-- 6. SEED DATA
-- ============================================================================

-- --- 6.1 Departments -------------------------------------------------------
INSERT INTO Department (Department_name) VALUES ('Computer Science');
INSERT INTO Department (Department_name) VALUES ('Electronics');
INSERT INTO Department (Department_name) VALUES ('Mechanical Engineering');
INSERT INTO Department (Department_name) VALUES ('Civil Engineering');
INSERT INTO Department (Department_name) VALUES ('Information Science');

-- --- 6.2 Postal codes ------------------------------------------------------
INSERT INTO Postal_Codes (Pincode, City) VALUES ('560001', 'Bengaluru');
INSERT INTO Postal_Codes (Pincode, City) VALUES ('400001', 'Mumbai');
INSERT INTO Postal_Codes (Pincode, City) VALUES ('110001', 'New Delhi');
INSERT INTO Postal_Codes (Pincode, City) VALUES ('600001', 'Chennai');
INSERT INTO Postal_Codes (Pincode, City) VALUES ('500001', 'Hyderabad');

-- --- 6.3 Equipment models --------------------------------------------------
INSERT INTO Equipment_Model (Model_name, Total_quantity) VALUES ('Digital Multimeter', 10);
INSERT INTO Equipment_Model (Model_name, Total_quantity) VALUES ('Oscilloscope', 5);
INSERT INTO Equipment_Model (Model_name, Total_quantity) VALUES ('Soldering Station', 8);
INSERT INTO Equipment_Model (Model_name, Total_quantity) VALUES ('Function Generator', 4);
INSERT INTO Equipment_Model (Model_name, Total_quantity) VALUES ('Breadboard Kit', 20);

-- --- 6.4 Staff -------------------------------------------------------------
INSERT INTO Staff (Staff_id, Staff_name, Role, Department_id) VALUES ('STF-01', 'Dr. Smith',    'Lab Assistant', 1);
INSERT INTO Staff (Staff_id, Staff_name, Role, Department_id) VALUES ('STF-02', 'Prof. Davis',  'Instructor',    1);
INSERT INTO Staff (Staff_id, Staff_name, Role, Department_id) VALUES ('STF-03', 'Dr. Patel',    'Lab Manager',   2);
INSERT INTO Staff (Staff_id, Staff_name, Role, Department_id) VALUES ('STF-04', 'Mr. Kumar',    'Technician',    3);
INSERT INTO Staff (Staff_id, Staff_name, Role, Department_id) VALUES ('STF-05', 'Ms. Lee',      'Lab Assistant', 4);
INSERT INTO Staff (Staff_id, Staff_name, Role, Department_id) VALUES ('STF-06', 'Ms. Zang',     'Technician',    5);

-- --- 6.5 Labs --------------------------------------------------------------
-- Attendance (6.12) is recorded against labs 1 and 2; 3 and 4 exist so the
-- lab picker and the per-lab reports are not trivially short of choices.
INSERT INTO Lab (Lab_name, Course_code, Department_id, Staff_id) VALUES ('Digital Electronics Lab',              'EC-201', 2, 'STF-01');
INSERT INTO Lab (Lab_name, Course_code, Department_id, Staff_id) VALUES ('Microcontroller Lab',                  'EC-202', 2, 'STF-02');
INSERT INTO Lab (Lab_name, Course_code, Department_id, Staff_id) VALUES ('Measurements & Instrumentation Lab',  'EC-203', 2, 'STF-03');
INSERT INTO Lab (Lab_name, Course_code, Department_id, Staff_id) VALUES ('Computing Lab',                       'CS-101', 1, 'STF-05');

-- --- 6.6 Students ----------------------------------------------------------
INSERT INTO Student (Student_id, First_name, Last_name, DOB, Email, Department_id)
  VALUES ('STD-01', 'John',    'Doe',      TO_DATE('2003-05-15','YYYY-MM-DD'), 'john@college.edu',    1);
INSERT INTO Student (Student_id, First_name, Last_name, DOB, Email, Department_id)
  VALUES ('STD-02', 'Alice',   'Brown',    TO_DATE('2004-02-20','YYYY-MM-DD'), 'alice@college.edu',   1);
INSERT INTO Student (Student_id, First_name, Last_name, DOB, Email, Department_id)
  VALUES ('STD-03', 'Rahul',   'Sharma',   TO_DATE('2003-08-10','YYYY-MM-DD'), 'rahul@college.edu',   2);
INSERT INTO Student (Student_id, First_name, Last_name, DOB, Email, Department_id)
  VALUES ('STD-04', 'Priya',   'Singh',    TO_DATE('2002-11-30','YYYY-MM-DD'), 'priya@college.edu',   3);
INSERT INTO Student (Student_id, First_name, Last_name, DOB, Email, Department_id)
  VALUES ('STD-05', 'David',   'Clark',    TO_DATE('2004-01-05','YYYY-MM-DD'), 'david@college.edu',   4);
INSERT INTO Student (Student_id, First_name, Last_name, DOB, Email, Department_id)
  VALUES ('STD-06', 'Chethan', 'Malatesh', TO_DATE('2006-08-10','YYYY-MM-DD'), 'chethan@college.edu', 5);

-- --- 6.7 Item units --------------------------------------------------------
-- All start Available. The borrows seeded in 6.13 move the three active ones
-- to 'Checked Out' through trg_borrow_after_insert - that is deliberate, it
-- proves the trigger works.
-- NOTE: BRKIT-5001 now correctly sits under model 5 (Breadboard Kit); in the
-- original sample.sql it was wrongly filed under model 4.
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (1, 'DMM-1001',   'Good',      'Available');
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (1, 'DMM-1002',   'Fair',      'Available');
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (1, 'DMM-1003',   'Good',      'Available');
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (2, 'OSC-2001',   'Good',      'Available');
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (2, 'OSC-2002',   'Good',      'Available');
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (3, 'SOLD-3001',  'Excellent', 'Available');
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (4, 'FUNC-4001',  'Good',      'Available');
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (5, 'BRKIT-5001', 'Fair',      'Available');
INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) VALUES (5, 'BRKIT-5002', 'Good',      'Available');

-- --- 6.8 Student addresses -------------------------------------------------
INSERT INTO Student_Address (Student_id, Address_type, Street, Pincode) VALUES ('STD-01', 'Permanent', '123 Main St',    '560001');
INSERT INTO Student_Address (Student_id, Address_type, Street, Pincode) VALUES ('STD-01', 'Resident',  '256 Main St',    '560001');
INSERT INTO Student_Address (Student_id, Address_type, Street, Pincode) VALUES ('STD-02', 'Resident',  'Hostel Block A', '560001');
INSERT INTO Student_Address (Student_id, Address_type, Street, Pincode) VALUES ('STD-03', 'Permanent', '45 Park Ave',    '400001');
INSERT INTO Student_Address (Student_id, Address_type, Street, Pincode) VALUES ('STD-04', 'Permanent', '78 Ring Road',   '110001');
INSERT INTO Student_Address (Student_id, Address_type, Street, Pincode) VALUES ('STD-05', 'Resident',  'Hostel Block B', '600001');
INSERT INTO Student_Address (Student_id, Address_type, Street, Pincode) VALUES ('STD-06', 'Permanent', '9 MG Road',      '500001');

-- --- 6.9 Qualifications ----------------------------------------------------
INSERT INTO Qualification (Staff_id, Qualifications) VALUES ('STF-01', 'M.Sc Computer Science');
INSERT INTO Qualification (Staff_id, Qualifications) VALUES ('STF-01', 'Ph.D Computer Networks');
INSERT INTO Qualification (Staff_id, Qualifications) VALUES ('STF-02', 'Ph.D Data Science');
INSERT INTO Qualification (Staff_id, Qualifications) VALUES ('STF-03', 'Ph.D Electronics');
INSERT INTO Qualification (Staff_id, Qualifications) VALUES ('STF-04', 'B.Tech Mechanical');
INSERT INTO Qualification (Staff_id, Qualifications) VALUES ('STF-05', 'M.Tech Civil');
INSERT INTO Qualification (Staff_id, Qualifications) VALUES ('STF-06', 'M.Sc Information Science');

-- --- 6.10 System accounts --------------------------------------------------
-- Password_hash = '<salt>$<sha256(salt || password)>' with salt = '<username>.aleam'
--   admin    -> admin123
--   staffN   -> pass123
--   studentN -> pass123
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('admin', 'admin.aleam$34188b419c597f70a721e60b21904a7204befc01c35a7a5453b62e29af6791bb', 'ADMIN', NULL);
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('staff1', 'staff1.aleam$58a02643db3b027c2504ac165a868fa420b585fd7390e9207cd2699fe37dee45', 'STAFF', 'STF-01');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('staff2', 'staff2.aleam$4d1f275ec892b194e3fbab4992f21cf6f70dbe51d4f232f2a722276fc8641e8b', 'STAFF', 'STF-02');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('staff3', 'staff3.aleam$8c382fc1d45c83c9c226c46e88f2b34c59c2219e6cb94991bd0851e928d26183', 'STAFF', 'STF-03');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('staff4', 'staff4.aleam$473208bbc0580d70fc363fec80a0e9b943a1c879e1556e08712faad8a42c1d6d', 'STAFF', 'STF-04');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('staff5', 'staff5.aleam$a5fc2d97c39dd22934b7497ee48dacd1c992ca1dda4b52468d3db53a145c7ffc', 'STAFF', 'STF-05');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('staff6', 'staff6.aleam$7bf9c3656ac337e6331d602a6cd094a2440958f39ad722ef13d5cfa5d78899a2', 'STAFF', 'STF-06');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('student1', 'student1.aleam$59999f72f0e82f648daa2f6c99c3a69b39c415dee1cc146e04b1691ee6c00846', 'STUDENT', 'STD-01');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('student2', 'student2.aleam$8e914a9875ee5b840b9358ed90a093312b527626418378d92d67c77f4e692905', 'STUDENT', 'STD-02');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('student3', 'student3.aleam$2b5967ba52f88985e5a133dca75100f6be454572f7fbe873f9dbb2252cbceb75', 'STUDENT', 'STD-03');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('student4', 'student4.aleam$1828bd95396c795241bb73121af0f8f987500909369f36d6d063dbcbed0d1130', 'STUDENT', 'STD-04');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('student5', 'student5.aleam$167d2ba827b7374f979e23f557b54130e0215116a8c7afbe8fcbd408ff60c3db', 'STUDENT', 'STD-05');
INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) VALUES
  ('student6', 'student6.aleam$2bc03681f1048d917c76fde4a5c7d6a8c0ffa3b1466c9d3742b6889186e7f885', 'STUDENT', 'STD-06');

-- --- 6.11 Penalties (historic, unrelated to the seeded borrows) ------------
-- Each insert fires trg_penalty_notify -> the student gets a PENALTY_DUE alert.
INSERT INTO Penalty (Student_id, Amount, Payment_status) VALUES ('STD-01',  50.00, 'Unpaid');
INSERT INTO Penalty (Student_id, Amount, Payment_status) VALUES ('STD-02', 150.50, 'Paid');
INSERT INTO Penalty (Student_id, Amount, Payment_status) VALUES ('STD-03',  25.00, 'Unpaid');
INSERT INTO Penalty (Student_id, Amount, Payment_status) VALUES ('STD-04', 100.00, 'Paid');
INSERT INTO Penalty (Student_id, Amount, Payment_status) VALUES ('STD-05', 200.00, 'Unpaid');

-- --- 6.12 Lab attendance ---------------------------------------------------
-- 10 sessions per student split across 2 labs x 5, with a different absence
-- pattern in each lab. The mix is chosen so the per-lab rule shows all three
-- interesting cases:
--
--   Student   Lab 1 (Digital Electronics)   Lab 2 (Microcontroller)   Overall
--   STD-01    5/5 = 100%                    3/5 = 60%  SHORTAGE       8/10 =  80%  OK
--   STD-02    3/5 =  60%  SHORTAGE          4/5 = 80%                 7/10 =  70%  SHORTAGE
--   STD-03    3/5 =  60%  SHORTAGE          3/5 = 60%  SHORTAGE       6/10 =  60%  SHORTAGE
--   STD-04    4/5 =  80%                    5/5 = 100%                9/10 =  90%  OK
--   STD-05    5/5 = 100%                    5/5 = 100%               10/10 = 100%  OK
--   STD-06    2/5 =  40%  SHORTAGE          3/5 = 60%  SHORTAGE       5/10 =  50%  SHORTAGE
--
-- STD-01 is the case the old overall-only rule could not express: fine overall,
-- short in one lab. The overall column still matches the figures the demo
-- narrative has always used. Five alerts are raised in total, each naming its lab.
DECLARE
  TYPE t_row IS RECORD (sid VARCHAR2(20), lab1_absent VARCHAR2(40), lab2_absent VARCHAR2(40));
  TYPE t_tab IS TABLE OF t_row INDEX BY PLS_INTEGER;
  v t_tab;
BEGIN
  v(1).sid := 'STD-01'; v(1).lab1_absent := '';        v(1).lab2_absent := '8,10';    -- 100% / 60%
  v(2).sid := 'STD-02'; v(2).lab1_absent := '1,2';     v(2).lab2_absent := '7';       --  60% / 80%
  v(3).sid := 'STD-03'; v(3).lab1_absent := '1,3';     v(3).lab2_absent := '6,9';     --  60% / 60%
  v(4).sid := 'STD-04'; v(4).lab1_absent := '4';       v(4).lab2_absent := '';        --  80% / 100%
  v(5).sid := 'STD-05'; v(5).lab1_absent := '';        v(5).lab2_absent := '';        -- 100% / 100%
  v(6).sid := 'STD-06'; v(6).lab1_absent := '1,2,3';   v(6).lab2_absent := '6,7';     --  40% / 60%

  FOR i IN 1 .. v.COUNT LOOP
    -- Lab 1: days 1-5, recorded by its in-charge STF-01.
    FOR d IN 1 .. 5 LOOP
      INSERT INTO Lab_Attendance (Student_id, Lab_id, Staff_id, Session_date, Status)
      VALUES (
        v(i).sid, 1, 'STF-01', DATE '2026-09-01' + d,
        CASE WHEN ',' || v(i).lab1_absent || ',' LIKE '%,' || d || ',%'
             THEN 'Absent' ELSE 'Present' END
      );
    END LOOP;

    -- Lab 2: days 6-10, recorded by its in-charge STF-02.
    FOR d IN 1 .. 5 LOOP
      INSERT INTO Lab_Attendance (Student_id, Lab_id, Staff_id, Session_date, Status)
      VALUES (
        v(i).sid, 2, 'STF-02', DATE '2026-09-01' + 5 + d,
        CASE WHEN ',' || v(i).lab2_absent || ',' LIKE '%,' || (5 + d) || ',%'
             THEN 'Absent' ELSE 'Present' END
      );
    END LOOP;
  END LOOP;
  COMMIT;
END;
/

-- --- 6.13 Borrows ----------------------------------------------------------
-- Three open loans (Return_date NULL) and two already returned. The open ones
-- become 'Checked Out' via the trigger; the returned ones leave their unit
-- Available.
INSERT INTO Borrows (Student_id, Model_id, Unit_barcode, Checkout_date, Due_date, Return_date, Staff_id) VALUES
  ('STD-01', 1, 'DMM-1001', TO_DATE('2026-09-10','YYYY-MM-DD'), TO_DATE('2026-09-17','YYYY-MM-DD'), NULL, 'STF-01');
INSERT INTO Borrows (Student_id, Model_id, Unit_barcode, Checkout_date, Due_date, Return_date, Staff_id) VALUES
  ('STD-02', 2, 'OSC-2001', TO_DATE('2026-09-11','YYYY-MM-DD'), TO_DATE('2026-09-18','YYYY-MM-DD'), NULL, 'STF-01');
INSERT INTO Borrows (Student_id, Model_id, Unit_barcode, Checkout_date, Due_date, Return_date, Staff_id) VALUES
  ('STD-03', 3, 'SOLD-3001', TO_DATE('2026-09-12','YYYY-MM-DD'), TO_DATE('2026-09-19','YYYY-MM-DD'), TO_DATE('2026-09-15','YYYY-MM-DD'), 'STF-03');
INSERT INTO Borrows (Student_id, Model_id, Unit_barcode, Checkout_date, Due_date, Return_date, Staff_id) VALUES
  ('STD-04', 4, 'FUNC-4001', TO_DATE('2026-09-13','YYYY-MM-DD'), TO_DATE('2026-09-20','YYYY-MM-DD'), NULL, 'STF-04');
INSERT INTO Borrows (Student_id, Model_id, Unit_barcode, Checkout_date, Due_date, Return_date, Staff_id) VALUES
  ('STD-05', 1, 'DMM-1002', TO_DATE('2026-09-14','YYYY-MM-DD'), TO_DATE('2026-09-21','YYYY-MM-DD'), TO_DATE('2026-09-20','YYYY-MM-DD'), 'STF-05');

COMMIT;

-- --- 6.14 Report seed: enrolments, penalty collections, borrow-to-lab links ---
INSERT INTO Lab_Enrollment (Student_id, Lab_id)
SELECT x.sid, x.lid FROM (
  SELECT s.Student_id AS sid, l.Lab_id AS lid FROM Student s, Lab l WHERE l.Lab_id IN (1, 2)
  UNION ALL SELECT 'STD-01', 3 FROM dual
  UNION ALL SELECT 'STD-04', 3 FROM dual
  UNION ALL SELECT 'STD-01', 4 FROM dual
  UNION ALL SELECT 'STD-02', 4 FROM dual
) x
WHERE NOT EXISTS (SELECT 1 FROM Lab_Enrollment e
                   WHERE e.Student_id = x.sid AND e.Lab_id = x.lid);

-- Only Collected_by / Paid_date change, so trg_penalty_paid_stamp does not fire.
UPDATE Penalty SET Collected_by = 'STF-01', Paid_date = DATE '2026-09-16'
 WHERE Student_id = 'STD-02' AND Payment_status = 'Paid';
UPDATE Penalty SET Collected_by = 'STF-03', Paid_date = DATE '2026-09-22'
 WHERE Student_id = 'STD-04' AND Payment_status = 'Paid';

UPDATE Borrows SET Lab_id = 1 WHERE Student_id = 'STD-01' AND Unit_barcode = 'DMM-1001';
UPDATE Borrows SET Lab_id = 2 WHERE Student_id = 'STD-02' AND Unit_barcode = 'OSC-2001';
UPDATE Borrows SET Lab_id = 1 WHERE Student_id = 'STD-03' AND Unit_barcode = 'SOLD-3001';
UPDATE Borrows SET Lab_id = 3 WHERE Student_id = 'STD-04' AND Unit_barcode = 'FUNC-4001';
UPDATE Borrows SET Lab_id = 1 WHERE Student_id = 'STD-05' AND Unit_barcode = 'DMM-1002';

COMMIT;


-- ============================================================================
-- 7. DEMO / VERIFICATION QUERIES
-- ============================================================================

PROMPT ---- 7.1  What did the triggers generate on their own?
SELECT Notification_type, COUNT(*) AS How_many
FROM Notification
GROUP BY Notification_type
ORDER BY How_many DESC;

PROMPT ---- 7.2  The notification inbox, newest first 
SELECT Notification_id AS ID, Recipient_type AS Rcpt, Recipient_id AS Rcpt_id,
       Notification_type AS Type, Is_read AS Read_flag,
       TO_CHAR(Created_date, 'DD-MON HH24:MI') AS Created, Message
FROM Notification
ORDER BY Notification_id DESC;

PROMPT ---- 7.3  Which units moved to Checked Out on their own? 
SELECT Model_id, Unit_barcode, Item_status FROM Item_Unit ORDER BY Model_id, Unit_barcode;

PROMPT ---- 7.4  Equipment availability (view) 
SELECT Model_name, Unit_barcode, Item_condition, Item_status FROM v_available_equipment ORDER BY Model_name;

PROMPT ---- 7.5  Active loans with an overdue flag (view) 
SELECT Student_id, Student_name, Model_name, Unit_barcode,
       TO_CHAR(Checkout_date,'DD-MON-YYYY') AS Checked_out,
       TO_CHAR(Due_date,'DD-MON-YYYY')      AS Due_back,
       Days_overdue, Due_status
FROM v_active_borrows
ORDER BY Due_date;

PROMPT ---- 7.6  Attendance league table (view) 
SELECT Student_id, Student_name, Total_sessions, Present_count, Absent_count,
       Attendance_pct, Attendance_status
FROM v_student_attendance
ORDER BY Attendance_pct;

PROMPT ---- 7.7  Attendance in WHICH lab, how much (view) 
-- The headline case: STD-01 is OK overall yet short in one lab.
SELECT Student_id, Student_name, Lab_name, Course_code,
       Total_sessions, Present_count, Absent_count, Attendance_pct, Attendance_status
FROM v_student_lab_attendance
ORDER BY Student_id, Lab_id;

PROMPT ---- 7.8  Per-lab shortage list (students below 75% in a lab) 
SELECT Student_id, Student_name, Lab_name, Attendance_pct
FROM v_student_lab_attendance
WHERE Attendance_status = 'SHORTAGE'
ORDER BY Attendance_pct;

PROMPT ---- 7.9  Outstanding money (view) 
SELECT Student_id, Student_name, Penalty_id, Amount, Payment_status
FROM v_unpaid_penalties
ORDER BY Amount DESC;

PROMPT ---- 7.10  Lab utilisation report (view) 
SELECT Model_name, Total_quantity, Units_registered, Units_available,
       Units_out, Times_borrowed
FROM v_lab_utilisation
ORDER BY Times_borrowed DESC;

PROMPT ---- 7.11  Students currently blocked from borrowing (unpaid dues) 
SELECT s.Student_id,
       s.First_name || ' ' || s.Last_name AS Student_name,
       d.Department_name,
       SUM(p.Amount) AS Total_owed
FROM Student s
JOIN Department d  ON s.Department_id = d.Department_id
JOIN Penalty  p    ON s.Student_id    = p.Student_id
WHERE p.Payment_status = 'Unpaid'
GROUP BY s.Student_id, s.First_name, s.Last_name, d.Department_name
ORDER BY Total_owed DESC;

PROMPT ---- 7.12  Department-wise borrowing activity 
SELECT d.Department_name,
       COUNT(DISTINCT s.Student_id) AS Students,
       COUNT(b.Unit_barcode)        AS Loans
FROM Department d
LEFT JOIN Student s ON d.Department_id = s.Department_id
LEFT JOIN Borrows b ON s.Student_id    = b.Student_id
GROUP BY d.Department_name
ORDER BY Loans DESC;

PROMPT ---- 7.13  Students who have NEVER returned anything late 
SELECT Student_id, First_name || ' ' || Last_name AS Student_name
FROM Student s
WHERE NOT EXISTS (
  SELECT 1 FROM Borrows b
   WHERE b.Student_id = s.Student_id
     AND b.Return_date IS NOT NULL
     AND TRUNC(b.Return_date) > TRUNC(b.Due_date)
);

PROMPT ---- ==== ALEAM schema, triggers and procedures installed ==== ----
