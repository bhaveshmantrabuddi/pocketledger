package dev.pocketledger

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.time.LocalDate
import java.time.YearMonth

class SyncEngineTest {
    private val month = YearMonth.of(2026, 10)
    private val date = LocalDate.of(2026, 10, 27)
    private fun expense(suffix: String = "01") = Expense("00000000-0000-4000-8000-0000000000$suffix", 1250, Category.FOOD, "Lunch", date)
    private class Store: SyncStore {
        val queue = mutableListOf<PendingOperation>()
        val acknowledged = mutableListOf<Long>()
        var visible = emptyList<Expense>()
        var budget = 200_000L
        var replacements = 0
        override fun pendingOperations() = queue.toList()
        override fun acknowledge(sequence: Long) { acknowledged += sequence; queue.removeAll { it.sequence == sequence } }
        override fun replaceRemoteIfClean(expenses: List<Expense>, budgetCents: Long): Boolean {
            if (queue.isNotEmpty()) return false
            visible = expenses; budget = budgetCents; replacements++; return true
        }
    }
    private inner class Api: LedgerApi {
        val remote = linkedMapOf<String, Expense>()
        var remoteBudget = 200_000L
        var creates = 0; var deletes = 0; var budgetWrites = 0; var pulls = 0
        var createFailure: ((Expense) -> Unit)? = null
        var deleteFailure: (() -> Unit)? = null
        var budgetFailure: (() -> Unit)? = null
        var onPull: (() -> Unit)? = null
        var dashboardFails = false
        override suspend fun create(expense: Expense) {
            creates++
            val existing = remote[expense.id]
            if (existing != null && existing != expense) throw IOException("ID conflict")
            remote[expense.id] = expense
            createFailure?.invoke(expense)
        }
        override suspend fun delete(id: String) { deletes++; remote.remove(id); deleteFailure?.invoke() }
        override suspend fun setBudget(cents: Long) { budgetWrites++; remoteBudget = cents; budgetFailure?.invoke() }
        override suspend fun expenses(): List<Expense> { pulls++; onPull?.invoke(); return remote.values.toList() }
        override suspend fun budget() = remoteBudget
        override suspend fun dashboard(month: YearMonth, asOf: LocalDate): Dashboard {
            if (dashboardFails) throw IOException("Worker unavailable")
            return Dashboard(month.toString(), asOf.toString(), remoteBudget, BudgetSummary(1250, remoteBudget - 1250, 1436, 49687, "under_budget"), emptyList())
        }
    }
    @Test fun partialFailureAcknowledgesOnlySuccessfulPrefixAndNeverPullsSnapshot() = runTest {
        val store = Store(); val api = Api()
        store.queue += PendingOperation.Create(1, expense("01")); store.queue += PendingOperation.Create(2, expense("02"))
        api.createFailure = { if (it.id.endsWith("02")) throw IOException("Disconnected") }
        try { SyncEngine(store, api).sync(month, date); fail("Expected sync failure") }
        catch (error: SyncFailure) { assertEquals(1, error.acknowledged) }
        assertEquals(listOf(1L), store.acknowledged)
        assertEquals(listOf(2L), store.queue.map { it.sequence })
        assertEquals(0, api.pulls); assertEquals(0, store.replacements)
    }
    @Test fun acceptedCreateWithLostResponseReplaysSameIdWithoutDuplicating() = runTest {
        val store = Store(); val api = Api(); val row = expense()
        store.queue += PendingOperation.Create(1, row)
        api.createFailure = { throw IOException("Response lost after commit") }
        runCatching { SyncEngine(store, api).sync(month, date) }
        assertEquals(1, api.remote.size); assertEquals(1, store.queue.size)
        api.createFailure = null
        SyncEngine(store, api).sync(month, date)
        assertEquals(2, api.creates); assertEquals(listOf(row), api.remote.values.toList())
        assertTrue(store.queue.isEmpty()); assertEquals(listOf(row), store.visible)
    }
    @Test fun createThenDeleteWhileOfflineFlushesInOrder() = runTest {
        val store = Store(); val api = Api(); val row = expense()
        store.queue += PendingOperation.Create(1, row); store.queue += PendingOperation.Delete(2, row.id)
        SyncEngine(store, api).sync(month, date)
        assertEquals(listOf(1L, 2L), store.acknowledged); assertTrue(api.remote.isEmpty()); assertTrue(store.visible.isEmpty())
    }
    @Test fun acceptedDeleteCanReplayAfterAnAmbiguousNetworkFailure() = runTest {
        val store = Store(); val api = Api(); val row = expense(); api.remote[row.id] = row
        store.queue += PendingOperation.Delete(1, row.id); api.deleteFailure = { throw IOException("Lost delete response") }
        runCatching { SyncEngine(store, api).sync(month, date) }
        assertTrue(api.remote.isEmpty()); assertEquals(1, store.queue.size)
        api.deleteFailure = null; SyncEngine(store, api).sync(month, date)
        assertEquals(2, api.deletes); assertTrue(store.queue.isEmpty())
    }
    @Test fun budgetRemainsQueuedAfterFailureAndReplaysAsAnIdempotentPut() = runTest {
        val store = Store(); val api = Api()
        store.queue += PendingOperation.Budget(1, 123_456)
        api.budgetFailure = { throw IOException("Lost budget response") }
        runCatching { SyncEngine(store, api).sync(month, date) }
        assertEquals(1, store.queue.size)
        api.budgetFailure = null; SyncEngine(store, api).sync(month, date)
        assertEquals(123_456L, store.budget); assertEquals(2, api.budgetWrites); assertTrue(store.queue.isEmpty())
    }
    @Test fun localChangeDuringPullPreventsSnapshotReplacement() = runTest {
        val store = Store(); val api = Api(); val local = expense("02"); store.visible = listOf(local)
        api.remote[expense().id] = expense()
        api.onPull = { store.queue += PendingOperation.Create(3, local) }
        val outcome = SyncEngine(store, api).sync(month, date)
        assertFalse(outcome.snapshotApplied); assertEquals(listOf(local), store.visible)
        assertEquals(1, store.queue.size); assertEquals(0, store.replacements); assertNull(outcome.dashboard)
    }
    @Test fun unavailableAnalyticsDoesNotUndoAcknowledgedExpenses() = runTest {
        val store = Store(); val api = Api(); store.queue += PendingOperation.Create(1, expense()); api.dashboardFails = true
        val result = SyncEngine(store, api).sync(month, date)
        assertTrue(result.snapshotApplied); assertTrue(store.queue.isEmpty()); assertEquals(listOf(expense()), store.visible)
        assertNull(result.dashboard); assertTrue(result.warning!!.contains("Worker unavailable"))
    }
    @Test fun idConflictLeavesOriginalPayloadQueuedForUserResolution() = runTest {
        val store = Store(); val api = Api(); val row = expense()
        store.queue += PendingOperation.Create(1, row); api.remote[row.id] = row.copy(amountCents = 900)
        val failure = runCatching { SyncEngine(store, api).sync(month, date) }.exceptionOrNull()
        assertTrue(failure is SyncFailure); assertEquals(row, (store.queue.single() as PendingOperation.Create).expense)
        assertEquals(0, api.pulls); assertEquals(900L, api.remote[row.id]!!.amountCents)
    }
    @Test fun cancellationDoesNotAcknowledgeInFlightOperation() = runTest {
        val store = Store(); val api = Api(); store.queue += PendingOperation.Create(1, expense())
        api.createFailure = { throw CancellationException("screen destroyed") }
        val failure = runCatching { SyncEngine(store, api).sync(month, date) }.exceptionOrNull()
        assertTrue(failure is CancellationException); assertEquals(1, store.queue.size); assertTrue(store.acknowledged.isEmpty())
    }
}
