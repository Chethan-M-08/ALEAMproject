"""
============================================================================
 ALEAM - Academic Lab Equipment & Attendance Manager
 FILE: aleam.py

 A single-file desktop application:
     * Frontend  -> CustomTkinter
     * Backend   -> this file (Database class)
     * Database  -> Oracle XE via the official 'oracledb' driver

 Run 'aleam.sql' in Oracle SQL Developer FIRST, then start this app.

 Three roles:
     ADMIN    - full CRUD over students, staff, equipment models and units,
                plus reports. Sees every notification.
     STAFF    - issues equipment, confirms returns, takes penalty payments,
                logs attendance, keeps the records.
     STUDENT  - read-only: available equipment, own borrow history,
                own attendance, own penalties and alerts.

 Passwords are never stored in clear. See hash_password() / verify_password().
============================================================================
"""

import hashlib
import hmac
import secrets
from datetime import datetime
import os
from dotenv import load_dotenv

import customtkinter as ctk
import oracledb
from tkinter import messagebox

load_dotenv()

# ============================================================================
# DATABASE CONFIGURATION  (edit these three lines for your machine)
# ============================================================================
DB_USER     = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASS")
DB_DSN      = "localhost:1521/XE"

# ============================================================================
# PASSWORD HASHING
#
# The hash column stores "<salt>$<sha256(salt + password)>". The salt is
# random per user, so two users with the same password get different hashes.
# The same routine generates the seed hashes in aleam.sql, which is why the
# seeded logins below work.
# ============================================================================

def hash_password(password: str, salt: str = None) -> str:
    """Return '<salt>$<hex digest>' ready for System_Account.Password_hash."""
    if salt is None:
        salt = secrets.token_hex(8)          # 16 hex characters
    digest = hashlib.sha256((salt + password).encode("utf-8")).hexdigest()
    return f"{salt}${digest}"


def verify_password(password: str, stored: str) -> bool:
    """Re-hash the typed password with the stored salt and compare."""
    if not stored or "$" not in stored:
        return False
    salt, digest = stored.split("$", 1)
    candidate = hashlib.sha256((salt + password).encode("utf-8")).hexdigest()
    return hmac.compare_digest(candidate, digest)


# ============================================================================
# BACKEND  -  every SQL statement in the app lives in this one class
# ============================================================================
class Database:

    def __init__(self):
        self.conn = None
        self.cursor = None
        try:
            self.conn = oracledb.connect(user=DB_USER, password=DB_PASSWORD, dsn=DB_DSN)
            self.cursor = self.conn.cursor()
        except Exception as exc:
            messagebox.showerror(
                "Database Error",
                "Could not connect to Oracle.\n\n"
                f"{exc}\n\n"
                f"DSN: {DB_DSN}\nUser: {DB_USER}\n\n"
                "Check that Oracle XE is running and that you have run aleam.sql "
                "in Oracle SQL Developer."
            )
            raise SystemExit(1)

    def close(self):
        try:
            if self.cursor:
                self.cursor.close()
            if self.conn:
                self.conn.close()
        except Exception:
            pass

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------
    def _query(self, sql, params=()):
        self.cursor.execute(sql, params)
        return self.cursor.fetchall()

    def _execute(self, sql, params=()):
        self.cursor.execute(sql, params)
        self.conn.commit()

    def _run_two_out(self, procedure, in_params):
        """Call a procedure shaped (..., p_result OUT, p_message OUT)."""
        res = self.cursor.var(oracledb.DB_TYPE_VARCHAR, 40)
        msg = self.cursor.var(oracledb.DB_TYPE_VARCHAR, 600)
        binds = list(in_params) + [res, msg]
        placeholders = ",".join(f":{i+1}" for i in range(len(binds)))
        self.cursor.execute(f"BEGIN {procedure}({placeholders}); END;", binds)
        return res.getvalue(), msg.getvalue()

    # ------------------------------------------------------------------
    # authentication
    # ------------------------------------------------------------------
    def authenticate(self, username, password):
        """Return (role, reference_id) on success, otherwise None."""
        rows = self._query(
            "SELECT Access_role, Reference_id, Password_hash "
            "  FROM System_Account WHERE Username = :1",
            (username,),
        )
        if not rows:
            return None
        role, ref_id, stored_hash = rows[0]
        if not verify_password(password, stored_hash):
            return None
        return role, ref_id

    # ------------------------------------------------------------------
    # shared lookups (used to populate dropdowns)
    # ------------------------------------------------------------------
    def get_departments(self):
        return self._query("SELECT Department_id, Department_name FROM Department ORDER BY Department_id")

    def get_students(self):
        return self._query(
            "SELECT Student_id, First_name || ' ' || Last_name "
            "  FROM Student ORDER BY Student_id"
        )

    def get_staff_list(self):
        return self._query("SELECT Staff_id, Staff_name FROM Staff ORDER BY Staff_id")

    def get_models(self):
        return self._query(
            "SELECT Model_id, Model_name FROM Equipment_Model ORDER BY Model_id"
        )

    def get_pincodes(self):
        return self._query("SELECT Pincode, City FROM Postal_Codes ORDER BY Pincode")

    def get_labs(self):
        return self._query(
            "SELECT Lab_id, Lab_name, Course_code FROM Lab ORDER BY Lab_id"
        )

    # ==================================================================
    # STUDENT-VIEW QUERIES
    # ==================================================================
    def get_available_equipment(self):
        return self._query(
            "SELECT Model_name, Unit_barcode, Item_condition, Item_status "
            "  FROM v_available_equipment ORDER BY Model_name, Unit_barcode"
        )

    def get_student_borrows(self, student_id):
        return self._query(
            "SELECT Model_name, Unit_barcode, "
            "       TO_CHAR(Checkout_date,'DD-MON-YYYY'), "
            "       TO_CHAR(Due_date,'DD-MON-YYYY'), "
            "       NVL(TO_CHAR(Return_date,'DD-MON-YYYY'),'-- still out --'), "
            "       CASE WHEN Return_date IS NOT NULL THEN 'Returned' "
            "            WHEN TRUNC(Due_date) < TRUNC(SYSDATE) THEN 'OVERDUE' "
            "            ELSE 'On loan' END "
            "  FROM Borrows b JOIN Equipment_Model m ON b.Model_id = m.Model_id "
            " WHERE b.Student_id = :1 ORDER BY b.Checkout_date DESC",
            (student_id,),
        )

    def get_student_penalties(self, student_id):
        return self._query(
            "SELECT Penalty_id, Amount, Payment_status "
            "  FROM Penalty WHERE Student_id = :1 ORDER BY Penalty_id",
            (student_id,),
        )

    def get_student_attendance_summary(self, student_id):
        rows = self._query(
            "SELECT Total_sessions, Present_count, Absent_count, "
            "       Attendance_pct, Attendance_status "
            "  FROM v_student_attendance WHERE Student_id = :1",
            (student_id,),
        )
        return rows[0] if rows else None

    def get_student_attendance_log(self, student_id):
        return self._query(
            "SELECT TO_CHAR(a.Session_date,'DD-MON-YYYY'), l.Lab_name, "
            "       a.Staff_id, st.Staff_name, a.Status "
            "  FROM Lab_Attendance a "
            "  JOIN Lab   l  ON a.Lab_id   = l.Lab_id "
            "  JOIN Staff st ON a.Staff_id = st.Staff_id "
            " WHERE a.Student_id = :1 ORDER BY a.Session_date DESC, l.Lab_name",
            (student_id,),
        )

    def get_student_lab_attendance(self, student_id):
        """Attendance broken down per lab - the 'which lab, how much' table."""
        return self._query(
            "SELECT Lab_name, Course_code, Total_sessions, Present_count, "
            "       Absent_count, Attendance_pct, Attendance_status "
            "  FROM v_student_lab_attendance "
            " WHERE Student_id = :1 ORDER BY Lab_id",
            (student_id,),
        )

    # ==================================================================
    # NOTIFICATIONS
    # ==================================================================
    def get_notifications(self, role, ref_id):
        if role == "ADMIN":
            return self._query(
                "SELECT Notification_id, Recipient_type, NVL(Recipient_id,'ALL'), "
                "       Notification_type, Message, "
                "       TO_CHAR(Created_date,'DD-MON-YYYY HH24:MI'), Is_read "
                "  FROM Notification ORDER BY Notification_id DESC"
            )
        return self._query(
            "SELECT Notification_id, Recipient_type, NVL(Recipient_id,'ALL'), "
            "       Notification_type, Message, "
            "       TO_CHAR(Created_date,'DD-MON-YYYY HH24:MI'), Is_read "
            "  FROM Notification "
            " WHERE Recipient_type = :1 AND (Recipient_id = :2 OR Recipient_id IS NULL) "
            " ORDER BY Notification_id DESC",
            (role, ref_id),
        )

    def count_unread(self, role, ref_id):
        if role == "ADMIN":
            rows = self._query("SELECT COUNT(*) FROM Notification WHERE Is_read = 'N'")
        else:
            rows = self._query(
                "SELECT COUNT(*) FROM Notification "
                " WHERE Is_read = 'N' AND Recipient_type = :1 "
                "   AND (Recipient_id = :2 OR Recipient_id IS NULL)",
                (role, ref_id),
            )
        return rows[0][0] if rows else 0

    def mark_notifications_read(self, role, ref_id):
        if role == "ADMIN":
            self._execute("UPDATE Notification SET Is_read = 'Y' WHERE Is_read = 'N'")
        else:
            self._execute(
                "UPDATE Notification SET Is_read = 'Y' "
                " WHERE Is_read = 'N' AND Recipient_type = :1 "
                "   AND (Recipient_id = :2 OR Recipient_id IS NULL)",
                (role, ref_id),
            )

    # ==================================================================
    # STAFF OPERATIONS  -  all delegated to stored procedures
    # ==================================================================
    def checkout_item(self, student_id, barcode, staff_id):
        return self._run_two_out("sp_checkout_item", [student_id, barcode, staff_id])

    def return_item(self, barcode, staff_id):
        return self._run_two_out("sp_return_item", [barcode, staff_id])

    def log_attendance(self, student_id, staff_id, lab_id, status):
        return self._run_two_out("sp_log_attendance",
                                 [student_id, staff_id, lab_id, status])

    def pay_penalty(self, student_id, penalty_id):
        return self._run_two_out("sp_pay_penalty", [student_id, int(penalty_id)])

    def check_overdue(self):
        """Run the overdue sweep. Returns the number of fresh alerts raised."""
        cnt = self.cursor.var(oracledb.DB_TYPE_NUMBER)
        self.cursor.execute("BEGIN sp_check_overdue(:1); END;", [cnt])
        value = cnt.getvalue()
        return int(value) if value is not None else 0

    # ---------------------------------------------------------------- staff views
    def get_active_borrows(self):
        return self._query(
            "SELECT Student_id, Student_name, Model_name, Unit_barcode, "
            "       TO_CHAR(Due_date,'DD-MON-YYYY'), Days_overdue, Due_status "
            "  FROM v_active_borrows ORDER BY Due_date"
        )

    def get_all_penalties(self):
        return self._query(
            "SELECT p.Student_id, s.First_name || ' ' || s.Last_name, "
            "       p.Penalty_id, p.Amount, p.Payment_status "
            "  FROM Penalty p JOIN Student s ON p.Student_id = s.Student_id "
            " ORDER BY p.Payment_status, p.Student_id"
        )

    def get_todays_attendance(self):
        return self._query(
            "SELECT a.Student_id, s.First_name || ' ' || s.Last_name, "
            "       l.Lab_name, a.Staff_id, a.Status "
            "  FROM Lab_Attendance a "
            "  JOIN Student s ON a.Student_id = s.Student_id "
            "  JOIN Lab     l ON a.Lab_id     = l.Lab_id "
            " WHERE TRUNC(a.Session_date) = TRUNC(SYSDATE) "
            " ORDER BY a.Student_id, l.Lab_name"
        )

    # ==================================================================
    # ADMIN CRUD
    #   Every method returns (ok: bool, message: str).
    # ==================================================================
    def _friendly(self, exc):
        text = str(exc)
        if "ORA-02292" in text:
            return "Cannot delete: other records still refer to this row. " \
                   "Remove those first, or leave the record in place."
        if "ORA-00001" in text:
            return "That id or value already exists."
        if "ORA-02291" in text:
            return "A referenced value does not exist (check the department or model)."
        if "ORA-01400" in text:
            return "A required field was left empty."
        if "ORA-12899" in text:
            return "One of the values is too long for its column."
        if "ORA-01861" in text or "ORA-01843" in text:
            return "Invalid date. Please use the format YYYY-MM-DD."
        if "ORA-20001" in text or "ORA-20002" in text:
            return text.split("ORA-", 1)[1].split(":", 1)[-1].strip()
        return text.split("\n")[0]

    # ---- students ----------------------------------------------------
    def add_student(self, sid, first, last, dob, email, dept_id,
                    username=None, password=None):
        try:
            self.cursor.execute(
                "INSERT INTO Student (Student_id, First_name, Last_name, DOB, Email, Department_id) "
                "VALUES (:1,:2,:3,:4,:5,:6)",
                (sid, first, last, dob, email, dept_id),
            )
            note = ""
            if username and password:
                self.cursor.execute(
                    "INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) "
                    "VALUES (:1,:2,'STUDENT',:3)",
                    (username, hash_password(password), sid),
                )
                note = f" Login '{username}' created."
            self.conn.commit()
            return True, f"Student {sid} added.{note}"
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def update_student(self, sid, first, last, dob, email, dept_id):
        try:
            self.cursor.execute(
                "UPDATE Student SET First_name=:1, Last_name=:2, DOB=:3, Email=:4, "
                "       Department_id=:5 WHERE Student_id=:6",
                (first, last, dob, email, dept_id, sid),
            )
            if self.cursor.rowcount == 0:
                return False, f"No student with id {sid}."
            self.conn.commit()
            return True, f"Student {sid} updated."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def delete_student(self, sid):
        try:
            self.cursor.execute("DELETE FROM System_Account WHERE Access_role='STUDENT' AND Reference_id=:1", (sid,))
            self.cursor.execute("DELETE FROM Student WHERE Student_id=:1", (sid,))
            self.conn.commit()
            return True, f"Student {sid} and their login were removed."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def reset_password(self, username, new_password):
        try:
            self.cursor.execute(
                "UPDATE System_Account SET Password_hash=:1 WHERE Username=:2",
                (hash_password(new_password), username),
            )
            if self.cursor.rowcount == 0:
                return False, f"No account named '{username}'."
            self.conn.commit()
            return True, f"Password for '{username}' was reset."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    # ---- staff -------------------------------------------------------
    def add_staff(self, staff_id, name, role, dept_id, username=None, password=None):
        try:
            self.cursor.execute(
                "INSERT INTO Staff (Staff_id, Staff_name, Role, Department_id) "
                "VALUES (:1,:2,:3,:4)",
                (staff_id, name, role, dept_id),
            )
            note = ""
            if username and password:
                self.cursor.execute(
                    "INSERT INTO System_Account (Username, Password_hash, Access_role, Reference_id) "
                    "VALUES (:1,:2,'STAFF',:3)",
                    (username, hash_password(password), staff_id),
                )
                note = f" Login '{username}' created."
            self.conn.commit()
            return True, f"Staff {staff_id} added.{note}"
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def update_staff(self, staff_id, name, role, dept_id):
        try:
            self.cursor.execute(
                "UPDATE Staff SET Staff_name=:1, Role=:2, Department_id=:3 WHERE Staff_id=:4",
                (name, role, dept_id, staff_id),
            )
            if self.cursor.rowcount == 0:
                return False, f"No staff member with id {staff_id}."
            self.conn.commit()
            return True, f"Staff {staff_id} updated."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def delete_staff(self, staff_id):
        try:
            self.cursor.execute("DELETE FROM Qualification WHERE Staff_id=:1", (staff_id,))
            self.cursor.execute("DELETE FROM System_Account WHERE Access_role='STAFF' AND Reference_id=:1", (staff_id,))
            self.cursor.execute("DELETE FROM Staff WHERE Staff_id=:1", (staff_id,))
            self.conn.commit()
            return True, f"Staff {staff_id}, their qualifications and login were removed."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    # ---- equipment models -------------------------------------------
    def add_model(self, name, total_qty):
        try:
            out = self.cursor.var(oracledb.DB_TYPE_NUMBER)
            self.cursor.execute(
                "INSERT INTO Equipment_Model (Model_name, Total_quantity) "
                "VALUES (:1,:2) RETURNING Model_id INTO :3",
                (name, int(total_qty), out),
            )
            self.conn.commit()
            return True, f"Model '{name}' added as id {out.getvalue()}."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def update_model(self, model_id, name, total_qty):
        try:
            self.cursor.execute(
                "UPDATE Equipment_Model SET Model_name=:1, Total_quantity=:2 WHERE Model_id=:3",
                (name, int(total_qty), int(model_id)),
            )
            if self.cursor.rowcount == 0:
                return False, f"No model with id {model_id}."
            self.conn.commit()
            return True, f"Model {model_id} updated."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def delete_model(self, model_id):
        try:
            self.cursor.execute("DELETE FROM Equipment_Model WHERE Model_id=:1", (int(model_id),))
            self.conn.commit()
            return True, f"Model {model_id} removed."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    # ---- item units --------------------------------------------------
    def add_unit(self, model_id, barcode, condition, status):
        try:
            self.cursor.execute(
                "INSERT INTO Item_Unit (Model_id, Unit_barcode, Condition, Item_status) "
                "VALUES (:1,:2,:3,:4)",
                (int(model_id), barcode, condition, status),
            )
            self.conn.commit()
            return True, f"Unit {barcode} added to model {model_id}."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def update_unit(self, model_id, barcode, condition, status):
        try:
            self.cursor.execute(
                "UPDATE Item_Unit SET Condition=:1, Item_status=:2 "
                " WHERE Model_id=:3 AND Unit_barcode=:4",
                (condition, status, int(model_id), barcode),
            )
            if self.cursor.rowcount == 0:
                return False, f"No unit {barcode} under model {model_id}."
            self.conn.commit()
            return True, f"Unit {barcode} updated."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    def delete_unit(self, model_id, barcode):
        try:
            self.cursor.execute(
                "DELETE FROM Item_Unit WHERE Model_id=:1 AND Unit_barcode=:2",
                (int(model_id), barcode),
            )
            self.conn.commit()
            return True, f"Unit {barcode} removed."
        except Exception as exc:
            self.conn.rollback()
            return False, self._friendly(exc)

    # ---- admin lists & reports ---------------------------------------
    def get_student_table(self):
        return self._query(
            "SELECT s.Student_id, s.First_name, s.Last_name, "
            "       NVL(TO_CHAR(s.DOB,'YYYY-MM-DD'),'-'), NVL(s.Email,'-'), "
            "       d.Department_name, NVL(s.Department_id,0) "
            "  FROM Student s LEFT JOIN Department d ON s.Department_id = d.Department_id "
            " ORDER BY s.Student_id"
        )

    def get_staff_table(self):
        return self._query(
            "SELECT st.Staff_id, st.Staff_name, NVL(st.Role,'-'), "
            "       NVL(d.Department_name,'-'), NVL(st.Department_id,0) "
            "  FROM Staff st LEFT JOIN Department d ON st.Department_id = d.Department_id "
            " ORDER BY st.Staff_id"
        )

    def get_model_table(self):
        return self._query("SELECT Model_id, Model_name, Total_quantity FROM Equipment_Model ORDER BY Model_id")

    def get_unit_table(self):
        return self._query(
            "SELECT u.Model_id, m.Model_name, u.Unit_barcode, "
            "       NVL(u.Condition,'-'), NVL(u.Item_status,'-') "
            "  FROM Item_Unit u JOIN Equipment_Model m ON u.Model_id = m.Model_id "
            " ORDER BY u.Model_id, u.Unit_barcode"
        )

    def get_utilisation(self):
        return self._query(
            "SELECT Model_name, Total_quantity, Units_registered, Units_available, "
            "       Units_out, Units_repair, Times_borrowed "
            "  FROM v_lab_utilisation ORDER BY Times_borrowed DESC"
        )

    def get_attendance_table(self):
        return self._query(
            "SELECT Student_id, Student_name, Total_sessions, Present_count, "
            "       Absent_count, Attendance_pct, Attendance_status "
            "  FROM v_student_attendance ORDER BY Attendance_pct"
        )

    def get_lab_attendance_table(self):
        """Every student's standing in every lab they attend."""
        return self._query(
            "SELECT Student_id, Student_name, Lab_name, Course_code, "
            "       Present_count, Total_sessions, Attendance_pct, Attendance_status "
            "  FROM v_student_lab_attendance "
            " ORDER BY Attendance_pct, Student_id, Lab_name"
        )

    def get_defaulter_table(self):
        return self._query(
            "SELECT Student_id, Student_name, Penalty_id, Amount, Payment_status "
            "  FROM v_unpaid_penalties ORDER BY Amount DESC"
        )


# ============================================================================
# SHARED UI PIECES
# ============================================================================

STATUS_COLOURS = {
    "Available":    "#2fa572",
    "Checked Out":  "#c9891a",
    "Under Repair": "#b5533c",
    "Retired":      "#6b6b6b",
    "Present":      "#2fa572",
    "Absent":       "#b5533c",
    "Paid":         "#2fa572",
    "Unpaid":       "#b5533c",
    "OK":           "#2fa572",
    "SHORTAGE":     "#b5533c",
    "OVERDUE":      "#b5533c",
    "ON TIME":      "#2fa572",
    "Returned":     "#2fa572",
    "On loan":      "#c9891a",
    "NOT ENOUGH DATA": "#6b6b6b",
    "Y":            "#2fa572",
    "N":            "#c9891a",
}


def make_table(parent, columns, rows, row_actions=None, widths=None):
    """
    Draw a scrollable table.

    columns      : list of heading strings
    rows         : list of tuples
    row_actions  : optional list of (label, callback) - one button set per row,
                   callback receives the whole row tuple
    widths       : optional list of pixel widths, one per column
    """
    for child in parent.winfo_children():
        child.destroy()

    if widths is None:
        widths = [150] * len(columns)
    elif len(widths) < len(columns):
        widths = list(widths) + [150] * (len(columns) - len(widths))

    body = ctk.CTkScrollableFrame(parent, fg_color="transparent")
    body.pack(fill="both", expand=True, padx=4, pady=4)

    for col, (heading, width) in enumerate(zip(columns, widths)):
        ctk.CTkLabel(
            body, text=heading, width=width, anchor="w",
            font=("Segoe UI", 12, "bold"), text_color="#8ecae6",
        ).grid(row=0, column=col, padx=4, pady=(4, 8), sticky="w")

    if not rows:
        ctk.CTkLabel(body, text="Nothing to show here yet.",
                     font=("Segoe UI", 12, "italic")).grid(
            row=1, column=0, columnspan=max(1, len(columns)), padx=8, pady=12, sticky="w")
        return

    for r, row in enumerate(rows, start=1):
        # Several queries return a trailing hidden key (e.g. Department_id) that
        # the row_actions callbacks need but the table must not show, so only
        # the columns that actually have a heading are drawn. The full tuple is
        # still handed to the callbacks below.
        for c, value in enumerate(row[:len(columns)]):
            text = "" if value is None else str(value)
            colour = STATUS_COLOURS.get(text)
            ctk.CTkLabel(
                body, text=text, width=widths[c], anchor="w",
                font=("Consolas", 12),
                text_color=colour if colour else ("gray90", "gray90"),
            ).grid(row=r, column=c, padx=4, pady=2, sticky="w")

        if row_actions:
            holder = ctk.CTkFrame(body, fg_color="transparent")
            holder.grid(row=r, column=len(columns), padx=6, pady=2, sticky="w")
            for label, callback in row_actions:
                ctk.CTkButton(
                    holder, text=label, width=62, height=24,
                    font=("Segoe UI", 11),
                    command=lambda cb=callback, rw=row: cb(rw),
                ).pack(side="left", padx=2)


class FormDialog(ctk.CTkToplevel):
    """
    A small modal form.

    fields : list of (key, label, kind, options, required)
             kind is 'entry' | 'password' | 'date' | 'combo'
             options is a list of (display, value) for 'combo', else None
    """

    def __init__(self, master, title, fields, initial=None):
        super().__init__(master)
        self.result = None
        self.fields = fields
        self.initial = initial or {}
        self.widgets = {}
        self.combo_maps = {}

        self.title(title)
        self.resizable(False, False)
        self.geometry(f"470x{110 + 58 * len(fields)}")
        self.transient(master.winfo_toplevel())

        ctk.CTkLabel(self, text=title, font=("Segoe UI", 16, "bold")).pack(pady=(16, 10))

        body = ctk.CTkFrame(self, fg_color="transparent")
        body.pack(fill="both", expand=True, padx=24)

        for key, label, kind, options, required in fields:
            ctk.CTkLabel(body, text=label + (" *" if required else ""),
                         font=("Segoe UI", 12), anchor="w").pack(fill="x", pady=(6, 0))

            current = self.initial.get(key, "")

            if kind == "combo":
                display = [d for d, _ in (options or [])]
                mapping = {d: v for d, v in (options or [])}
                widget = ctk.CTkComboBox(body, values=display, width=410)
                if current in mapping:
                    widget.set(current)
                elif display:
                    widget.set(display[0])
                self.combo_maps[key] = mapping
            else:
                widget = ctk.CTkEntry(body, width=410)
                if kind == "password":
                    widget.configure(show="*")
                if current:
                    widget.insert(0, str(current))

            widget.pack(pady=(2, 0))
            self.widgets[key] = widget

        buttons = ctk.CTkFrame(self, fg_color="transparent")
        buttons.pack(pady=18)
        ctk.CTkButton(buttons, text="Save", width=120, command=self._submit).pack(side="left", padx=8)
        ctk.CTkButton(buttons, text="Cancel", width=120, fg_color="gray35",
                      hover_color="gray25", command=self._cancel).pack(side="left", padx=8)

        self.bind("<Return>", lambda _e: self._submit())
        self.bind("<Escape>", lambda _e: self._cancel())
        self.after(200, self.grab_set)
        self.lift()

    def _submit(self):
        values = {}
        for key, label, kind, _options, required in self.fields:
            widget = self.widgets[key]
            if kind == "combo":
                chosen = widget.get()
                value = self.combo_maps[key].get(chosen, chosen)
            else:
                value = widget.get().strip()

            if required and (value is None or value == ""):
                messagebox.showerror("Missing value", f"'{label}' is required.", parent=self)
                return
            values[key] = value if value != "" else None

        self.result = values
        self.destroy()

    def _cancel(self):
        self.result = None
        self.destroy()


def ask_form(master, title, fields, initial=None):
    """Show FormDialog modally and return the dict of values, or None."""
    dialog = FormDialog(master, title, fields, initial)
    master.wait_window(dialog)
    return dialog.result


def status_row(label, value, parent, colour=None):
    frame = ctk.CTkFrame(parent, fg_color="transparent")
    frame.pack(fill="x", padx=6, pady=2)
    ctk.CTkLabel(frame, text=label, width=170, anchor="w",
                 font=("Segoe UI", 12)).pack(side="left")
    ctk.CTkLabel(frame, text=str(value), anchor="w", font=("Consolas", 12, "bold"),
                 text_color=colour or ("gray90", "gray90")).pack(side="left")


# ============================================================================
# LOGIN
# ============================================================================
class LoginFrame(ctk.CTkFrame):

    def __init__(self, parent, controller, db):
        super().__init__(parent)
        self.controller = controller
        self.db = db

        box = ctk.CTkFrame(self)
        box.place(relx=0.5, rely=0.5, anchor="center")

        ctk.CTkLabel(box, text="ALEAM", font=("Segoe UI", 40, "bold")).pack(padx=60, pady=(34, 0))
        ctk.CTkLabel(box, text="Academic Lab Equipment & Attendance Manager",
                     font=("Segoe UI", 12), text_color="gray60").pack(padx=60, pady=(0, 26))

        self.username_entry = ctk.CTkEntry(box, placeholder_text="Username", width=280)
        self.username_entry.pack(pady=8)

        self.password_entry = ctk.CTkEntry(box, placeholder_text="Password", show="*", width=280)
        self.password_entry.pack(pady=8)

        ctk.CTkButton(box, text="Log in", width=280, height=36,
                      font=("Segoe UI", 14, "bold"), command=self.login).pack(pady=(18, 6))

        self.hint = ctk.CTkLabel(box, text="", font=("Segoe UI", 11), text_color="#b5533c")
        self.hint.pack(pady=(0, 6))

        ctk.CTkLabel(box, text="Demo logins   admin/admin123    staff1/pass123    student1/pass123",
                     font=("Segoe UI", 10), text_color="gray55").pack(padx=40, pady=(4, 26))

        self.password_entry.bind("<Return>", lambda _e: self.login())

    def login(self):
        username = self.username_entry.get().strip()
        password = self.password_entry.get()

        if not username or not password:
            self.hint.configure(text="Enter both a username and a password.")
            return

        result = self.db.authenticate(username, password)
        if not result:
            self.hint.configure(text="Invalid username or password.")
            self.password_entry.delete(0, "end")
            return

        role, ref_id = result
        self.hint.configure(text="")
        self.password_entry.delete(0, "end")
        self.controller.start_session(username, role, ref_id)


# ============================================================================
# BASE DASHBOARD  -  shared header, logout and notification helper
# ============================================================================
class DashboardBase(ctk.CTkFrame):

    heading = "Dashboard"

    def __init__(self, parent, controller, db):
        super().__init__(parent)
        self.controller = controller
        self.db = db
        self._build_header()

    def _build_header(self):
        header = ctk.CTkFrame(self, corner_radius=0)
        header.pack(fill="x")

        ctk.CTkLabel(header, text=self.heading, font=("Segoe UI", 22, "bold")
                     ).pack(side="left", padx=20, pady=12)

        ctk.CTkButton(header, text="Log out", width=90, fg_color="gray35",
                      hover_color="gray25", command=self.controller.logout
                      ).pack(side="right", padx=16, pady=12)

        self.identity = ctk.CTkLabel(header, text="", font=("Segoe UI", 12),
                                     text_color="gray65")
        self.identity.pack(side="right", padx=6)

    def _identity_text(self):
        role = self.controller.current_user_role
        who = self.controller.current_username
        ref = self.controller.current_ref_id or "-"
        unread = self.db.count_unread(role, self.controller.current_ref_id)
        alert = f"   |   {unread} unread alert(s)" if unread else ""
        return f"{who}  ({role}, {ref}){alert}"

    def announce_pending_alerts(self):
        unread = self.db.count_unread(self.controller.current_user_role,
                                     self.controller.current_ref_id)
        if unread:
            messagebox.showinfo(
                "You have alerts",
                f"There {'is' if unread == 1 else 'are'} {unread} unread notification(s) "
                "waiting for you.\n\nOpen the Notifications tab to read them."
            )

    def notifications_panel(self, parent):
        for child in parent.winfo_children():
            child.destroy()

        # The button lives in its own bar so that make_table() - which clears
        # every child of the frame it is given - cannot wipe it out.
        bar = ctk.CTkFrame(parent, fg_color="transparent")
        bar.pack(fill="x", padx=8, pady=(6, 0))
        ctk.CTkButton(bar, text="Mark all as read", width=150,
                      command=lambda: self._mark_read(parent)).pack(side="right")

        body = ctk.CTkFrame(parent, fg_color="transparent")
        body.pack(fill="both", expand=True)

        rows = self.db.get_notifications(self.controller.current_user_role,
                                         self.controller.current_ref_id)
        make_table(
            body,
            ["#", "Type", "Message", "When", "Read"],
            rows,
            widths=[45, 165, 520, 130, 55],
        )

    def _mark_read(self, parent):
        self.db.mark_notifications_read(self.controller.current_user_role,
                                        self.controller.current_ref_id)
        self.notifications_panel(parent)
        self.refresh_identity()

    def refresh_identity(self):
        self.identity.configure(text=self._identity_text())


# ============================================================================
# STUDENT DASHBOARD
# ============================================================================
class StudentDashboard(DashboardBase):

    heading = "Student Dashboard"

    def __init__(self, parent, controller, db):
        super().__init__(parent, controller, db)

        self.tabs = ctk.CTkTabview(self)
        self.tabs.pack(fill="both", expand=True, padx=14, pady=12)

        self.tab_equip = self.tabs.add("Available Equipment")
        self.tab_borrow = self.tabs.add("My Borrow History")
        self.tab_attend = self.tabs.add("My Attendance")
        self.tab_fines = self.tabs.add("My Penalties")
        self.tab_alerts = self.tabs.add("Notifications")

    def refresh_data(self):
        self.refresh_identity()
        sid = self.controller.current_ref_id

        make_table(self.tab_equip,
                   ["Model", "Barcode", "Condition", "Status"],
                   self.db.get_available_equipment(),
                   widths=[260, 140, 130, 130])

        make_table(self.tab_borrow,
                   ["Model", "Barcode", "Checked out", "Due", "Returned", "State"],
                   self.db.get_student_borrows(sid),
                   widths=[230, 130, 130, 130, 150, 110])

        for child in self.tab_attend.winfo_children():
            child.destroy()

        summary = self.db.get_student_attendance_summary(sid)
        if summary:
            total, present, absent, pct, verdict = summary
            card = ctk.CTkFrame(self.tab_attend)
            card.pack(fill="x", padx=8, pady=10)
            ctk.CTkLabel(card, text="Overall lab attendance",
                         font=("Segoe UI", 14, "bold")).pack(anchor="w", padx=14, pady=(12, 6))
            status_row("Sessions attended", present, card)
            status_row("Sessions missed", absent, card)
            status_row("Total sessions", total, card)
            status_row("Attendance", f"{pct} %", card, STATUS_COLOURS.get(verdict))
            status_row("Standing", verdict, card, STATUS_COLOURS.get(verdict))

            if verdict == "SHORTAGE":
                ctk.CTkLabel(card,
                             text="You are below the 75% requirement. Please meet your lab instructor.",
                             font=("Segoe UI", 12), text_color="#b5533c"
                             ).pack(anchor="w", padx=14, pady=(4, 12))
            else:
                ctk.CTkLabel(card, text="", font=("Segoe UI", 4)).pack(pady=4)

        ctk.CTkLabel(self.tab_attend, text="Attendance by lab",
                     font=("Segoe UI", 13, "bold")).pack(anchor="w", padx=8, pady=(14, 0))
        lab_frame = ctk.CTkFrame(self.tab_attend, fg_color="transparent")
        lab_frame.pack(fill="x")
        make_table(lab_frame,
                   ["Lab", "Code", "Sessions", "Present", "Absent", "%", "Standing"],
                   self.db.get_student_lab_attendance(sid),
                   widths=[250, 90, 90, 90, 90, 80, 130])

        ctk.CTkLabel(self.tab_attend, text="Session-by-session log",
                     font=("Segoe UI", 13, "bold")).pack(anchor="w", padx=8, pady=(10, 0))
        log_frame = ctk.CTkFrame(self.tab_attend, fg_color="transparent")
        log_frame.pack(fill="both", expand=True)
        make_table(log_frame,
                   ["Date", "Lab", "Staff id", "Staff", "Status"],
                   self.db.get_student_attendance_log(sid),
                   widths=[140, 240, 100, 190, 110])

        make_table(self.tab_fines,
                   ["Penalty #", "Amount (Rs.)", "Status"],
                   self.db.get_student_penalties(sid),
                   widths=[130, 150, 150])

        self.notifications_panel(self.tab_alerts)


# ============================================================================
# STAFF DASHBOARD
# ============================================================================
class StaffDashboard(DashboardBase):

    heading = "Staff Dashboard"

    def __init__(self, parent, controller, db):
        super().__init__(parent, controller, db)

        self.tabs = ctk.CTkTabview(self)
        self.tabs.pack(fill="both", expand=True, padx=14, pady=12)

        self.tab_issue = self.tabs.add("Issue Equipment")
        self.tab_return = self.tabs.add("Confirm Return")
        self.tab_attend = self.tabs.add("Log Attendance")
        self.tab_fines = self.tabs.add("Penalty Payments")
        self.tab_records = self.tabs.add("Records")
        self.tab_alerts = self.tabs.add("Notifications")

        self._build_issue()
        self._build_return()
        self._build_attend()
        self._build_fines()
        self._build_records()

    # ---------------------------------------------------------------- tabs
    def _student_picker(self, parent, row):
        students = self.db.get_students()
        options = [f"{sid}  -  {name}" for sid, name in students]
        combo = ctk.CTkComboBox(parent, values=options, width=320)
        combo.grid(row=row, column=1, padx=10, pady=8, sticky="w")
        return combo

    @staticmethod
    def _picker_value(combo):
        return combo.get().split("  -  ")[0].strip()

    def _lab_picker(self, parent, row):
        labs = self.db.get_labs()
        options = [f"{lid}  -  {name} ({code})" for lid, name, code in labs]
        combo = ctk.CTkComboBox(parent, values=options, width=320)
        combo.grid(row=row, column=1, padx=10, pady=8, sticky="w")
        return combo

    def _build_issue(self):
        ctk.CTkLabel(self.tab_issue, text="Issue a unit to a student",
                     font=("Segoe UI", 15, "bold")).grid(
            row=0, column=0, columnspan=2, padx=18, pady=(18, 6), sticky="w")

        ctk.CTkLabel(self.tab_issue, text="Student").grid(row=1, column=0, padx=18, pady=8, sticky="w")
        self.issue_student = self._student_picker(self.tab_issue, 1)

        ctk.CTkLabel(self.tab_issue, text="Unit barcode").grid(row=2, column=0, padx=18, pady=8, sticky="w")
        self.issue_barcode = ctk.CTkEntry(self.tab_issue, width=320, placeholder_text="e.g. DMM-1003")
        self.issue_barcode.grid(row=2, column=1, padx=10, pady=8, sticky="w")

        ctk.CTkButton(self.tab_issue, text="Process checkout", width=200,
                      command=self.process_checkout).grid(row=3, column=0, columnspan=2, pady=18)

        ctk.CTkLabel(self.tab_issue,
                     text="A student with unpaid penalties cannot borrow.\n"
                          "The 7-day due date and the stock update are applied by the database.",
                     font=("Segoe UI", 11), text_color="gray60", justify="left"
                     ).grid(row=4, column=0, columnspan=2, padx=18, pady=(6, 0), sticky="w")

    def _build_return(self):
        ctk.CTkLabel(self.tab_return, text="Take a unit back",
                     font=("Segoe UI", 15, "bold")).pack(anchor="w", padx=18, pady=(18, 6))

        row = ctk.CTkFrame(self.tab_return, fg_color="transparent")
        row.pack(anchor="w", padx=18, pady=8)
        ctk.CTkLabel(row, text="Unit barcode").pack(side="left", padx=(0, 12))
        self.return_barcode = ctk.CTkEntry(row, width=240, placeholder_text="e.g. DMM-1001")
        self.return_barcode.pack(side="left")

        ctk.CTkButton(self.tab_return, text="Confirm return", width=200,
                      command=self.process_return).pack(anchor="w", padx=18, pady=18)

        ctk.CTkButton(self.tab_return, text="Run overdue sweep", width=200,
                      fg_color="#c9891a", hover_color="#a9760f",
                      command=self.process_overdue).pack(anchor="w", padx=18)

        ctk.CTkLabel(self.tab_return,
                     text="The sweep raises an alert for every item still out past its due date.\n"
                          "Late returns automatically create a penalty at Rs.5 per day.",
                     font=("Segoe UI", 11), text_color="gray60", justify="left"
                     ).pack(anchor="w", padx=18, pady=(14, 0))

    def _build_attend(self):
        ctk.CTkLabel(self.tab_attend, text="Record today's attendance",
                     font=("Segoe UI", 15, "bold")).grid(
            row=0, column=0, columnspan=2, padx=18, pady=(18, 6), sticky="w")

        ctk.CTkLabel(self.tab_attend, text="Student").grid(row=1, column=0, padx=18, pady=8, sticky="w")
        self.attend_student = self._student_picker(self.tab_attend, 1)

        ctk.CTkLabel(self.tab_attend, text="Lab").grid(row=2, column=0, padx=18, pady=8, sticky="w")
        self.attend_lab = self._lab_picker(self.tab_attend, 2)

        ctk.CTkLabel(self.tab_attend, text="Status").grid(row=3, column=0, padx=18, pady=8, sticky="w")
        self.attend_status = ctk.CTkComboBox(self.tab_attend, values=["Present", "Absent"], width=320)
        self.attend_status.grid(row=3, column=1, padx=10, pady=8, sticky="w")

        ctk.CTkButton(self.tab_attend, text="Submit attendance", width=200,
                      command=self.process_attendance).grid(row=4, column=0, columnspan=2, pady=18)

        ctk.CTkLabel(self.tab_attend,
                     text="Attendance is recorded against the chosen lab. If it drops\n"
                          "the student below 75% in that lab, the database raises an\n"
                          "attendance-shortage alert naming the lab automatically.",
                     font=("Segoe UI", 11), text_color="gray60", justify="left"
                     ).grid(row=5, column=0, columnspan=2, padx=18, sticky="w")

    def _build_fines(self):
        ctk.CTkLabel(self.tab_fines, text="Settle a penalty",
                     font=("Segoe UI", 15, "bold")).pack(anchor="w", padx=18, pady=(18, 6))
        ctk.CTkLabel(self.tab_fines,
                     text="Pick an unpaid penalty from the list below and press Accept payment.",
                     font=("Segoe UI", 11), text_color="gray60").pack(anchor="w", padx=18)

        self.fines_table = ctk.CTkFrame(self.tab_fines)
        self.fines_table.pack(fill="both", expand=True, padx=10, pady=10)

    def _build_records(self):
        sub = ctk.CTkTabview(self.tab_records)
        sub.pack(fill="both", expand=True, padx=6, pady=6)

        self.rec_borrows = sub.add("Open Loans")
        self.rec_attend = sub.add("Today's Attendance")
        self.rec_fines = sub.add("All Penalties")

        ctk.CTkButton(self.tab_records, text="Refresh records", width=150,
                      command=self.refresh_data).place(relx=0.99, rely=0.01, anchor="ne")

    # ---------------------------------------------------------------- actions
    def process_checkout(self):
        student = self._picker_value(self.issue_student)
        barcode = self.issue_barcode.get().strip().upper()

        if not barcode:
            messagebox.showerror("Missing barcode", "Enter the unit barcode to issue.")
            return

        result, message = self.db.checkout_item(
            student, barcode, self.controller.current_ref_id)

        if result == "OK":
            messagebox.showinfo("Checkout complete", message)
            self.issue_barcode.delete(0, "end")
        else:
            messagebox.showerror("Checkout refused", message)
        self.refresh_identity()

    def process_return(self):
        barcode = self.return_barcode.get().strip().upper()
        if not barcode:
            messagebox.showerror("Missing barcode", "Enter the unit barcode to return.")
            return

        result, message = self.db.return_item(barcode, self.controller.current_ref_id)

        if result == "OK":
            messagebox.showinfo("Return recorded", message)
            self.return_barcode.delete(0, "end")
        else:
            messagebox.showerror("Could not return", message)
        self.refresh_identity()

    def process_overdue(self):
        try:
            raised = self.db.check_overdue()
        except Exception as exc:
            messagebox.showerror("Sweep failed", str(exc))
            return

        if raised:
            messagebox.showinfo("Overdue sweep",
                                f"{raised} overdue alert(s) raised and sent to the students.")
        else:
            messagebox.showinfo("Overdue sweep", "Nothing new to report. All loans are current.")
        self.refresh_identity()

    def process_attendance(self):
        student = self._picker_value(self.attend_student)
        lab = self._picker_value(self.attend_lab)
        status = self.attend_status.get()

        if not lab:
            messagebox.showerror("Missing lab", "Choose the lab this session belongs to.")
            return

        result, message = self.db.log_attendance(
            student, self.controller.current_ref_id, int(lab), status)

        if result == "OK":
            messagebox.showinfo("Attendance recorded", message)
        else:
            messagebox.showerror("Could not record", message)
        self.refresh_identity()

    def pay_selected(self, row):
        student_id, student_name, penalty_id, amount, state = row
        if state == "Paid":
            messagebox.showinfo("Already settled", f"Penalty #{penalty_id} is already paid.")
            return

        if not messagebox.askyesno(
                "Confirm payment",
                f"Accept Rs.{amount} from {student_name} ({student_id}) "
                f"for penalty #{penalty_id}?"):
            return

        result, message = self.db.pay_penalty(student_id, penalty_id)
        if result == "OK":
            messagebox.showinfo("Payment accepted", message)
        else:
            messagebox.showerror("Payment failed", message)
        self.refresh_data()

    # ---------------------------------------------------------------- refresh
    def refresh_data(self):
        self.refresh_identity()

        make_table(self.fines_table,
                   ["Student", "Name", "Penalty #", "Amount (Rs.)", "Status"],
                   self.db.get_all_penalties(),
                   row_actions=[("Accept payment", self.pay_selected)],
                   widths=[100, 190, 100, 120, 100])

        make_table(self.rec_borrows,
                   ["Student", "Name", "Model", "Barcode", "Due", "Days late", "State"],
                   self.db.get_active_borrows(),
                   widths=[100, 180, 210, 130, 120, 90, 110])

        make_table(self.rec_attend,
                   ["Student", "Name", "Lab", "Recorded by", "Status"],
                   self.db.get_todays_attendance(),
                   widths=[110, 190, 230, 130, 110])

        make_table(self.rec_fines,
                   ["Student", "Name", "Penalty #", "Amount (Rs.)", "Status"],
                   self.db.get_all_penalties(),
                   widths=[110, 230, 110, 130, 110])

        self.notifications_panel(self.tab_alerts)


# ============================================================================
# ADMIN DASHBOARD
# ============================================================================
class AdminDashboard(DashboardBase):

    heading = "Admin Dashboard"

    def __init__(self, parent, controller, db):
        super().__init__(parent, controller, db)

        self.tabs = ctk.CTkTabview(self)
        self.tabs.pack(fill="both", expand=True, padx=14, pady=12)

        self.tab_students = self.tabs.add("Students")
        self.tab_staff = self.tabs.add("Staff")
        self.tab_equip = self.tabs.add("Equipment")
        self.tab_reports = self.tabs.add("Reports")
        self.tab_alerts = self.tabs.add("Notifications")

        self._build_students()
        self._build_staff()
        self._build_equipment()
        self._build_reports()

    # ---------------------------------------------------------------- helpers
    def _dept_options(self):
        return [(name, str(did)) for did, name in self.db.get_departments()]

    def _hold(self, parent):
        frame = ctk.CTkFrame(parent, fg_color="transparent")
        frame.pack(fill="both", expand=True, padx=6, pady=6)
        return frame

    def _toolbar(self, parent, buttons):
        bar = ctk.CTkFrame(parent, fg_color="transparent")
        bar.pack(fill="x", padx=8, pady=(8, 0))
        for label, callback in buttons:
            ctk.CTkButton(bar, text=label, width=140, command=callback).pack(side="left", padx=4)

    # ---------------------------------------------------------------- students
    def _build_students(self):
        self._toolbar(self.tab_students, [
            ("Add student", self.add_student),
            ("Manage logins", self.manage_logins),
        ])
        self.students_table = self._hold(self.tab_students)

    def add_student(self):
        fields = [
            ("sid",   "Student id (e.g. STD-07)", "entry", None, True),
            ("first", "First name",                "entry", None, True),
            ("last",  "Last name",                 "entry", None, True),
            ("dob",   "Date of birth (YYYY-MM-DD)", "date", None, False),
            ("email", "Email",                     "entry", None, False),
            ("dept",  "Department",                "combo", self._dept_options(), True),
            ("uname", "Login username (optional)", "entry", None, False),
            ("pwd",   "Login password (optional)", "password", None, False),
        ]
        values = ask_form(self, "Add student", fields)
        if not values:
            return
        ok, message = self.db.add_student(
            values["sid"], values["first"], values["last"], values["dob"],
            values["email"], values["dept"], values["uname"], values["pwd"])
        self._report(ok, message, self.refresh_data)

    def edit_student(self, row):
        sid, first, last, dob, email, dept_name, dept_id = row
        fields = [
            ("first", "First name", "entry", None, True),
            ("last",  "Last name",  "entry", None, True),
            ("dob",   "Date of birth (YYYY-MM-DD)", "date", None, False),
            ("email", "Email",      "entry", None, False),
            ("dept",  "Department", "combo", self._dept_options(), True),
        ]
        initial = {"first": first, "last": last,
                   "dob": "" if dob == "-" else dob,
                   "email": "" if email == "-" else email,
                   "dept": dept_name}
        values = ask_form(self, f"Edit student {sid}", fields, initial)
        if not values:
            return
        ok, message = self.db.update_student(
            sid, values["first"], values["last"], values["dob"],
            values["email"], values["dept"])
        self._report(ok, message, self.refresh_data)

    def remove_student(self, row):
        sid = row[0]
        if not messagebox.askyesno("Delete student",
                                   f"Delete student {sid} and their login?\n\n"
                                   "This fails if they still have borrow, attendance or "
                                   "penalty records - that is the database protecting history."):
            return
        ok, message = self.db.delete_student(sid)
        self._report(ok, message, self.refresh_data)

    def manage_logins(self):
        users = self.db._query(
            "SELECT Username, Access_role, NVL(Reference_id,'-') FROM System_Account "
            " ORDER BY Access_role, Username")
        holder = ctk.CTkToplevel(self.winfo_toplevel())
        holder.title("Accounts")
        holder.geometry("620x480")
        holder.transient(self.winfo_toplevel())
        ctk.CTkLabel(holder, text="All system accounts",
                     font=("Segoe UI", 15, "bold")).pack(pady=10)

        body = ctk.CTkFrame(holder, fg_color="transparent")
        body.pack(fill="both", expand=True)
        make_table(body, ["Username", "Role", "Linked to"], users,
                   row_actions=[("Reset password", lambda r: self.reset_password(r[0]))],
                   widths=[180, 120, 150])
        holder.after(200, holder.grab_set)

    def reset_password(self, username):
        fields = [("pwd", f"New password for '{username}'", "password", None, True)]
        values = ask_form(self, "Reset password", fields)
        if not values:
            return
        ok, message = self.db.reset_password(username, values["pwd"])
        messagebox.showinfo("Reset password", message) if ok else \
            messagebox.showerror("Reset password", message)

    # ---------------------------------------------------------------- staff
    def _build_staff(self):
        self._toolbar(self.tab_staff, [("Add staff", self.add_staff)])
        self.staff_table = self._hold(self.tab_staff)

    def add_staff(self):
        fields = [
            ("sid",   "Staff id (e.g. STF-07)", "entry", None, True),
            ("name",  "Full name",              "entry", None, True),
            ("role",  "Role (e.g. Lab Assistant)", "entry", None, True),
            ("dept",  "Department",            "combo", self._dept_options(), True),
            ("uname", "Login username (optional)", "entry", None, False),
            ("pwd",   "Login password (optional)", "password", None, False),
        ]
        values = ask_form(self, "Add staff", fields)
        if not values:
            return
        ok, message = self.db.add_staff(
            values["sid"], values["name"], values["role"],
            values["dept"], values["uname"], values["pwd"])
        self._report(ok, message, self.refresh_data)

    def edit_staff(self, row):
        sid, name, role, dept_name, dept_id = row
        fields = [
            ("name", "Full name", "entry", None, True),
            ("role", "Role",      "entry", None, True),
            ("dept", "Department", "combo", self._dept_options(), True),
        ]
        initial = {"name": name, "role": role, "dept": dept_name}
        values = ask_form(self, f"Edit staff {sid}", fields, initial)
        if not values:
            return
        ok, message = self.db.update_staff(sid, values["name"], values["role"], values["dept"])
        self._report(ok, message, self.refresh_data)

    def remove_staff(self, row):
        sid = row[0]
        if not messagebox.askyesno("Delete staff member",
                                   f"Delete {sid}, their qualifications and their login?"):
            return
        ok, message = self.db.delete_staff(sid)
        self._report(ok, message, self.refresh_data)

    # ---------------------------------------------------------------- equipment
    def _build_equipment(self):
        sub = ctk.CTkTabview(self.tab_equip)
        sub.pack(fill="both", expand=True, padx=6, pady=6)

        self.eq_models = sub.add("Models")
        self.eq_units = sub.add("Item Units")

        self._toolbar(self.eq_models, [("Add model", self.add_model)])
        self.models_table = self._hold(self.eq_models)

        self._toolbar(self.eq_units, [("Add unit", self.add_unit)])
        self.units_table = self._hold(self.eq_units)

    def _model_options(self):
        return [(name, str(mid)) for mid, name in self.db.get_models()]

    def add_model(self):
        fields = [("name", "Model name", "entry", None, True),
                  ("qty",  "Total quantity", "entry", None, True)]
        values = ask_form(self, "Add equipment model", fields)
        if not values:
            return
        ok, message = self.db.add_model(values["name"], values["qty"])
        self._report(ok, message, self.refresh_data)

    def edit_model(self, row):
        model_id, name, qty = row
        fields = [("name", "Model name", "entry", None, True),
                  ("qty",  "Total quantity", "entry", None, True)]
        values = ask_form(self, f"Edit model {model_id}", fields,
                          {"name": name, "qty": qty})
        if not values:
            return
        ok, message = self.db.update_model(model_id, values["name"], values["qty"])
        self._report(ok, message, self.refresh_data)

    def remove_model(self, row):
        model_id = row[0]
        if not messagebox.askyesno("Delete model",
                                   f"Delete model {model_id} ({row[1]})?\n\n"
                                   "This fails if any physical units or loans still exist."):
            return
        ok, message = self.db.delete_model(model_id)
        self._report(ok, message, self.refresh_data)

    def add_unit(self):
        fields = [
            ("model", "Model",           "combo", self._model_options(), True),
            ("code",  "Unit barcode",    "entry", None, True),
            ("cond",  "Condition",       "combo",
             [("Excellent", "Excellent"), ("Good", "Good"),
              ("Fair", "Fair"), ("Poor", "Poor")], True),
            ("state", "Status", "combo",
             [("Available", "Available"), ("Under Repair", "Under Repair"),
              ("Retired", "Retired")], True),
        ]
        values = ask_form(self, "Add item unit", fields)
        if not values:
            return
        ok, message = self.db.add_unit(values["model"], values["code"].upper(),
                                       values["cond"], values["state"])
        self._report(ok, message, self.refresh_data)

    def edit_unit(self, row):
        model_id, model_name, barcode, condition, state = row
        fields = [
            ("cond",  "Condition", "combo",
             [("Excellent", "Excellent"), ("Good", "Good"),
              ("Fair", "Fair"), ("Poor", "Poor")], True),
            ("state", "Status", "combo",
             [("Available", "Available"), ("Checked Out", "Checked Out"),
              ("Under Repair", "Under Repair"), ("Retired", "Retired")], True),
        ]
        values = ask_form(self, f"Edit unit {barcode}", fields,
                          {"cond": condition, "state": state})
        if not values:
            return
        ok, message = self.db.update_unit(model_id, barcode, values["cond"], values["state"])
        self._report(ok, message, self.refresh_data)

    def remove_unit(self, row):
        model_id, _model_name, barcode = row[0], row[1], row[2]
        if not messagebox.askyesno("Delete unit", f"Delete unit {barcode}?"):
            return
        ok, message = self.db.delete_unit(model_id, barcode)
        self._report(ok, message, self.refresh_data)

    # ---------------------------------------------------------------- reports
    def _build_reports(self):
        sub = ctk.CTkTabview(self.tab_reports)
        sub.pack(fill="both", expand=True, padx=6, pady=6)

        self.rep_util = sub.add("Lab Utilisation")
        self.rep_attend = sub.add("Attendance")
        self.rep_lab_attend = sub.add("Attendance by Lab")
        self.rep_dues = sub.add("Outstanding Dues")

    # ---------------------------------------------------------------- shared
    def _report(self, ok, message, on_success):
        if ok:
            messagebox.showinfo("Done", message)
            on_success()
        else:
            messagebox.showerror("Not done", message)

    def refresh_data(self):
        self.refresh_identity()

        make_table(self.students_table,
                   ["Id", "First name", "Last name", "DOB", "Email", "Department"],
                   self.db.get_student_table(),
                   row_actions=[("Edit", self.edit_student), ("Delete", self.remove_student)],
                   widths=[90, 120, 120, 110, 190, 180])

        make_table(self.staff_table,
                   ["Id", "Name", "Role", "Department"],
                   self.db.get_staff_table(),
                   row_actions=[("Edit", self.edit_staff), ("Delete", self.remove_staff)],
                   widths=[90, 200, 160, 200])

        make_table(self.models_table,
                   ["Id", "Model", "Total qty"],
                   self.db.get_model_table(),
                   row_actions=[("Edit", self.edit_model), ("Delete", self.remove_model)],
                   widths=[70, 280, 120])

        make_table(self.units_table,
                   ["Model id", "Model", "Barcode", "Condition", "Status"],
                   self.db.get_unit_table(),
                   row_actions=[("Edit", self.edit_unit), ("Delete", self.remove_unit)],
                   widths=[90, 220, 140, 130, 130])

        make_table(self.rep_util,
                   ["Model", "Owned", "Units", "Available", "Out", "Repair", "Times borrowed"],
                   self.db.get_utilisation(),
                   widths=[230, 80, 80, 100, 70, 90, 130])

        make_table(self.rep_attend,
                   ["Id", "Student", "Sessions", "Present", "Absent", "%", "Standing"],
                   self.db.get_attendance_table(),
                   widths=[90, 200, 90, 90, 90, 80, 140])

        make_table(self.rep_lab_attend,
                   ["Id", "Student", "Lab", "Code", "Present", "Sessions", "%", "Standing"],
                   self.db.get_lab_attendance_table(),
                   widths=[80, 170, 230, 80, 80, 90, 70, 120])

        make_table(self.rep_dues,
                   ["Id", "Student", "Penalty #", "Amount (Rs.)", "Status"],
                   self.db.get_defaulter_table(),
                   widths=[90, 220, 110, 130, 110])

        self.notifications_panel(self.tab_alerts)


# ============================================================================
# APPLICATION SHELL  -  owns the session and the frame router
# ============================================================================
class ALEAMApp(ctk.CTk):

    def __init__(self):
        super().__init__()
        self.title("ALEAM - Academic Lab Equipment & Attendance Manager")
        self.geometry("1180x720")
        self.minsize(1000, 640)

        self.db = Database()

        self.current_username = None
        self.current_user_role = None
        self.current_ref_id = None

        self.frames = {}
        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(0, weight=1)

        for FrameClass in (LoginFrame, StudentDashboard, StaffDashboard, AdminDashboard):
            name = FrameClass.__name__
            frame = FrameClass(parent=self, controller=self, db=self.db)
            self.frames[name] = frame
            frame.grid(row=0, column=0, sticky="nsew")

        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.show_frame("LoginFrame")

    # ---------------------------------------------------------------- routing
    def show_frame(self, name):
        for frame in self.frames.values():
            frame.grid_remove()

        frame = self.frames[name]
        frame.grid(row=0, column=0, sticky="nsew")

        if hasattr(frame, "refresh_data"):
            frame.refresh_data()

    # ---------------------------------------------------------------- session
    def start_session(self, username, role, ref_id):
        self.current_username = username
        self.current_user_role = role
        self.current_ref_id = ref_id

        if role == "STUDENT":
            self.show_frame("StudentDashboard")
        elif role == "STAFF":
            self.show_frame("StaffDashboard")
        else:
            self.show_frame("AdminDashboard")

        self.frames[self._active_frame_name()].announce_pending_alerts()

    def _active_frame_name(self):
        if self.current_user_role == "STUDENT":
            return "StudentDashboard"
        if self.current_user_role == "STAFF":
            return "StaffDashboard"
        return "AdminDashboard"

    def logout(self):
        if not messagebox.askyesno("Log out", "Log out of ALEAM?"):
            return
        self.current_username = None
        self.current_user_role = None
        self.current_ref_id = None
        self.show_frame("LoginFrame")

    def on_close(self):
        self.db.close()
        self.destroy()


def main():
    ctk.set_appearance_mode("Dark")
    ctk.set_default_color_theme("blue")
    try:
        app = ALEAMApp()
    except SystemExit:
        return                      # Database() already explained why
    app.mainloop()


if __name__ == "__main__":
    main()
