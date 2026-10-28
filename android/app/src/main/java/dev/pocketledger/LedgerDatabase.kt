package dev.pocketledger

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.time.LocalDate

class LedgerDatabase(context: Context, name: String = "pocketledger.db") : SQLiteOpenHelper(context, name, null, 1), SyncStore {
    init { setWriteAheadLoggingEnabled(true) }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE expenses (id TEXT PRIMARY KEY, amount INTEGER NOT NULL, category TEXT NOT NULL, note TEXT NOT NULL, date TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)")
        db.execSQL("CREATE TABLE pending (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, entity_id TEXT, amount INTEGER, category TEXT, note TEXT, date TEXT)")
        db.execSQL("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execSQL("CREATE TABLE dashboards (month TEXT PRIMARY KEY, payload TEXT NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = error("Unsupported database migration: $oldVersion to $newVersion")
    private inline fun <T> transaction(block: (SQLiteDatabase) -> T): T {
        val db = writableDatabase
        db.beginTransaction()
        try { val result = block(db); db.setTransactionSuccessful(); return result }
        finally { db.endTransaction() }
    }
    private fun values(expense: Expense) = ContentValues().apply {
        put("id", expense.id); put("amount", expense.amountCents); put("category", expense.category.key)
        put("note", expense.note); put("date", expense.date.toString()); put("deleted", 0)
    }
    private fun Cursor.expense() = Expense(getString(getColumnIndexOrThrow("id")), getLong(getColumnIndexOrThrow("amount")), Category.fromKey(getString(getColumnIndexOrThrow("category"))), getString(getColumnIndexOrThrow("note")), LocalDate.parse(getString(getColumnIndexOrThrow("date"))))
    private fun setting(db: SQLiteDatabase, key: String, default: String): String = db.rawQuery("SELECT value FROM settings WHERE key=?", arrayOf(key)).use { if (it.moveToFirst()) it.getString(0) else default }
    private fun putSetting(db: SQLiteDatabase, key: String, value: String) = db.insertWithOnConflict("settings", null, ContentValues().apply { put("key", key); put("value", value) }, SQLiteDatabase.CONFLICT_REPLACE)
    @Synchronized fun snapshot(): LedgerSnapshot {
        val db = readableDatabase
        val items = db.rawQuery("SELECT e.*, EXISTS(SELECT 1 FROM pending p WHERE p.entity_id=e.id) AS is_pending FROM expenses e WHERE deleted=0 ORDER BY date DESC, id ASC", null).use { cursor ->
            buildList { while (cursor.moveToNext()) add(LocalExpense(cursor.expense(), cursor.getInt(cursor.getColumnIndexOrThrow("is_pending")) == 1)) }
        }
        val pending = db.rawQuery("SELECT COUNT(*) FROM pending", null).use { it.moveToFirst(); it.getInt(0) }
        return LedgerSnapshot(items, setting(db, "budget", "200000").toLong(), pending, setting(db, "endpoint", DEFAULT_ENDPOINT))
    }
    @Synchronized fun add(expense: Expense) = transaction { db ->
        expense.validate()
        db.insertOrThrow("expenses", null, values(expense))
        db.insertOrThrow("pending", null, ContentValues().apply {
            put("kind", "create"); put("entity_id", expense.id); put("amount", expense.amountCents)
            put("category", expense.category.key); put("note", expense.note); put("date", expense.date.toString())
        })
    }
    @Synchronized fun delete(id: String) = transaction { db ->
        val updated = db.update("expenses", ContentValues().apply { put("deleted", 1) }, "id=? AND deleted=0", arrayOf(id))
        if (updated > 0) db.insertOrThrow("pending", null, ContentValues().apply { put("kind", "delete"); put("entity_id", id) })
    }
    @Synchronized fun setBudget(cents: Long) = transaction { db ->
        require(cents in 1..Money.MAX_CENTS) { "Invalid budget." }
        putSetting(db, "budget", cents.toString())
        db.insertOrThrow("pending", null, ContentValues().apply { put("kind", "budget"); put("amount", cents) })
    }
    @Synchronized fun setEndpoint(endpoint: String) {
        val normalized = HttpLedgerApi.normalizeEndpoint(endpoint)
        transaction { db ->
            val oldEndpoint = setting(db, "endpoint", DEFAULT_ENDPOINT)
            val bound = setting(db, "server_bound", "false") == "true"
            val pending = db.rawQuery("SELECT COUNT(*) FROM pending", null).use { it.moveToFirst(); it.getLong(0) }
            require(!bound || pending == 0L || oldEndpoint == normalized) { "Sync pending changes before switching away from a server you have already used." }
            if (oldEndpoint != normalized) {
                // First-time endpoint setup keeps every offline operation and local row intact.
                if (bound || pending == 0L) {
                    db.delete("expenses", null, null)
                    putSetting(db, "budget", "200000")
                }
                db.delete("dashboards", null, null)
                putSetting(db, "server_bound", "false")
            }
            putSetting(db, "endpoint", normalized)
        }
    }
    @Synchronized override fun pendingOperations(): List<PendingOperation> = readableDatabase.rawQuery("SELECT * FROM pending ORDER BY sequence ASC", null).use { cursor ->
        buildList {
            while (cursor.moveToNext()) {
                val sequence = cursor.getLong(cursor.getColumnIndexOrThrow("sequence"))
                val id = cursor.getString(cursor.getColumnIndexOrThrow("entity_id"))
                when (cursor.getString(cursor.getColumnIndexOrThrow("kind"))) {
                    "create" -> add(PendingOperation.Create(sequence, Expense(id, cursor.getLong(cursor.getColumnIndexOrThrow("amount")), Category.fromKey(cursor.getString(cursor.getColumnIndexOrThrow("category"))), cursor.getString(cursor.getColumnIndexOrThrow("note")), LocalDate.parse(cursor.getString(cursor.getColumnIndexOrThrow("date"))))))
                    "delete" -> add(PendingOperation.Delete(sequence, id))
                    "budget" -> add(PendingOperation.Budget(sequence, cursor.getLong(cursor.getColumnIndexOrThrow("amount"))))
                    else -> error("Unknown pending operation")
                }
            }
        }
    }
    @Synchronized override fun acknowledge(sequence: Long) = transaction { db ->
        db.delete("pending", "sequence=?", arrayOf(sequence.toString()))
        putSetting(db, "server_bound", "true")
        db.execSQL("DELETE FROM expenses WHERE deleted=1 AND NOT EXISTS(SELECT 1 FROM pending p WHERE p.entity_id=expenses.id)")
        Unit
    }
    @Synchronized override fun replaceRemoteIfClean(expenses: List<Expense>, budgetCents: Long): Boolean = transaction { db ->
        val count = db.rawQuery("SELECT COUNT(*) FROM pending", null).use { it.moveToFirst(); it.getLong(0) }
        if (count != 0L) return@transaction false
        expenses.forEach { it.validate() }
        require(expenses.map { it.id }.distinct().size == expenses.size) { "Server returned duplicate expense IDs." }
        require(budgetCents in 1..Money.MAX_CENTS) { "Server returned an invalid budget." }
        db.delete("expenses", null, null)
        expenses.forEach { db.insertOrThrow("expenses", null, values(it)) }
        putSetting(db, "budget", budgetCents.toString())
        putSetting(db, "server_bound", "true")
        true
    }
    @Synchronized fun cacheDashboard(dashboard: Dashboard) {
        writableDatabase.insertWithOnConflict("dashboards", null, ContentValues().apply { put("month", dashboard.month); put("payload", JsonCodec.dashboardJson(dashboard).toString()) }, SQLiteDatabase.CONFLICT_REPLACE)
    }
    @Synchronized fun cachedDashboard(month: String): Dashboard? = readableDatabase.rawQuery("SELECT payload FROM dashboards WHERE month=?", arrayOf(month)).use {
        if (it.moveToFirst()) runCatching { JsonCodec.dashboard(org.json.JSONObject(it.getString(0))) }.getOrNull() else null
    }
    companion object { const val DEFAULT_ENDPOINT = "http://10.0.2.2:8080" }
}
