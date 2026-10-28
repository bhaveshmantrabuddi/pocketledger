package dev.pocketledger

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.time.LocalDate
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class OfflinePersistenceTest {
    @Test fun expenseDeleteAndBudgetQueueSurviveDatabaseReopen() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val name = "offline-${UUID.randomUUID()}.db"
        val row = Expense(UUID.randomUUID().toString(), 1250, Category.FOOD, "Synthetic lunch", LocalDate.of(2026, 10, 27))
        try {
            LedgerDatabase(context, name).use { db -> db.add(row); db.setBudget(150_000); db.delete(row.id) }
            LedgerDatabase(context, name).use { reopened ->
                assertTrue(reopened.snapshot().expenses.isEmpty())
                assertEquals(150_000L, reopened.snapshot().budgetCents)
                val pending = reopened.pendingOperations()
                assertEquals(3, pending.size)
                assertEquals(row, (pending[0] as PendingOperation.Create).expense)
                assertTrue(pending[1] is PendingOperation.Budget)
                assertTrue(pending[2] is PendingOperation.Delete)
                assertFalse(reopened.replaceRemoteIfClean(emptyList(), 200_000))
                pending.forEach { reopened.acknowledge(it.sequence) }
                assertTrue(reopened.replaceRemoteIfClean(emptyList(), 150_000))
            }
        } finally { context.deleteDatabase(name) }
    }
    @Test fun pendingQueueBlocksSwitchingTheTargetServer() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val name = "endpoint-${UUID.randomUUID()}.db"
        try {
            LedgerDatabase(context, name).use { db ->
                db.setBudget(100_000)
                db.acknowledge(db.pendingOperations().single().sequence)
                db.setBudget(120_000)
                assertThrows(IllegalArgumentException::class.java) { db.setEndpoint("http://127.0.0.1:8080") }
                assertEquals(LedgerDatabase.DEFAULT_ENDPOINT, db.snapshot().endpoint)
            }
        } finally { context.deleteDatabase(name) }
    }
    @Test fun firstTimeEndpointSetupPreservesOfflineExpensesAndBudget() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val name = "first-setup-${UUID.randomUUID()}.db"
        val row = Expense(UUID.randomUUID().toString(), 1250, Category.FOOD, "Synthetic lunch", LocalDate.of(2026, 10, 27))
        try {
            LedgerDatabase(context, name).use { db ->
                db.add(row); db.setBudget(150_000)
                db.setEndpoint("http://192.168.1.50:8080")
            }
            LedgerDatabase(context, name).use { db ->
                assertEquals("http://192.168.1.50:8080", db.snapshot().endpoint)
                assertEquals(row, db.snapshot().expenses.single().expense)
                assertEquals(150_000L, db.snapshot().budgetCents)
                assertEquals(2, db.pendingOperations().size)
            }
        } finally { context.deleteDatabase(name) }
    }

}
