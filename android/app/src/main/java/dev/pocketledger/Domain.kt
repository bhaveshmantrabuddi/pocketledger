package dev.pocketledger

import java.time.LocalDate
import java.time.YearMonth
import java.util.Locale
import java.util.UUID

object Money {
    const val MAX_CENTS = 100_000_000L
    fun parseCents(input: String): Long {
        val value = input.trim()
        require(Regex("(?:0|[1-9][0-9]{0,6})(?:\\.[0-9]{1,2})?").matches(value)) {
            "Enter a dollar amount with at most two decimal places, such as 12.50."
        }
        val parts = value.split('.')
        val cents = parts[0].toLong() * 100L + (parts.getOrNull(1)?.padEnd(2, '0')?.toLong() ?: 0L)
        require(cents in 1..MAX_CENTS) { "Amount must be between $0.01 and $1,000,000.00." }
        return cents
    }
    fun format(cents: Long): String {
        val magnitude = kotlin.math.abs(cents)
        val dollars = String.format(Locale.US, "%,d", magnitude / 100)
        return "${if (cents < 0) "−" else ""}$$dollars.${(magnitude % 100).toString().padStart(2, '0')}"
    }
    fun input(cents: Long): String = "${cents / 100}.${(cents % 100).toString().padStart(2, '0')}"
}

enum class Category(val key: String, val title: String, val symbol: String) {
    FOOD("food", "Food", "F"), TRANSPORT("transport", "Transport", "T"),
    HOUSING("housing", "Housing", "H"), SHOPPING("shopping", "Shopping", "S"),
    HEALTH("health", "Health", "+"), ENTERTAINMENT("entertainment", "Entertainment", "E"),
    OTHER("other", "Other", "O");
    companion object { fun fromKey(key: String) = entries.first { it.key == key } }
}

data class Expense(val id: String, val amountCents: Long, val category: Category, val note: String, val date: LocalDate) {
    fun validate(): Expense {
        require(Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}").matches(id)) { "Invalid expense ID." }
        UUID.fromString(id)
        require(amountCents in 1..Money.MAX_CENTS) { "Invalid amount." }
        require(date.year in 2000..2100) { "Choose a date between 2000 and 2100." }
        require(note.codePointCount(0, note.length) <= 140) { "Note must be at most 140 characters." }
        return this
    }
    companion object {
        fun parseDate(value: String): LocalDate {
            require(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}").matches(value)) { "Use YYYY-MM-DD for the date." }
            val date = runCatching { LocalDate.parse(value) }.getOrElse { throw IllegalArgumentException("Enter a valid calendar date.") }
            require(date.year in 2000..2100) { "Choose a date between 2000 and 2100." }
            return date
        }
    }
}

data class LocalExpense(val expense: Expense, val pending: Boolean)
data class LedgerSnapshot(val expenses: List<LocalExpense>, val budgetCents: Long, val pendingCount: Int, val endpoint: String)
data class CategoryTotal(val category: Category, val spentCents: Long, val count: Int)
data class BudgetSummary(val spentCents: Long, val remainingCents: Long, val projectedCents: Long, val dailyAllowanceCents: Long, val status: String)
data class Dashboard(val month: String, val asOf: String, val monthlyLimitCents: Long, val summary: BudgetSummary, val categories: List<CategoryTotal>)

sealed interface PendingOperation {
    val sequence: Long
    data class Create(override val sequence: Long, val expense: Expense): PendingOperation
    data class Delete(override val sequence: Long, val id: String): PendingOperation
    data class Budget(override val sequence: Long, val cents: Long): PendingOperation
}

interface LedgerApi {
    suspend fun create(expense: Expense)
    suspend fun delete(id: String)
    suspend fun setBudget(cents: Long)
    suspend fun expenses(): List<Expense>
    suspend fun budget(): Long
    suspend fun dashboard(month: YearMonth, asOf: LocalDate): Dashboard
}

interface SyncStore {
    fun pendingOperations(): List<PendingOperation>
    fun acknowledge(sequence: Long)
    /** The queue check and replacement must occur in one local transaction. */
    fun replaceRemoteIfClean(expenses: List<Expense>, budgetCents: Long): Boolean
}

data class SyncOutcome(val pushed: Int, val snapshotApplied: Boolean, val dashboard: Dashboard?, val warning: String?)
class SyncFailure(val acknowledged: Int, cause: Exception): Exception(cause.message ?: "The server could not be reached.", cause)

class SyncEngine(private val store: SyncStore, private val api: LedgerApi) {
    suspend fun sync(month: YearMonth, asOf: LocalDate): SyncOutcome {
        var pushed = 0
        try {
            for (operation in store.pendingOperations()) {
                when (operation) {
                    is PendingOperation.Create -> api.create(operation.expense)
                    is PendingOperation.Delete -> api.delete(operation.id)
                    is PendingOperation.Budget -> api.setBudget(operation.cents)
                }
                store.acknowledge(operation.sequence)
                pushed++
            }
            val remoteExpenses = api.expenses()
            val remoteBudget = api.budget()
            val applied = store.replaceRemoteIfClean(remoteExpenses, remoteBudget)
            if (!applied) return SyncOutcome(pushed, false, null, "New local changes are waiting. Sync again to send them.")
            return try { SyncOutcome(pushed, true, api.dashboard(month, asOf), null) }
            catch (error: kotlinx.coroutines.CancellationException) { throw error }
            catch (error: Exception) { SyncOutcome(pushed, true, null, "Expenses synced. Analytics unavailable: ${error.message}") }
        } catch (error: kotlinx.coroutines.CancellationException) { throw error }
        catch (error: Exception) { throw SyncFailure(pushed, error) }
    }
}
