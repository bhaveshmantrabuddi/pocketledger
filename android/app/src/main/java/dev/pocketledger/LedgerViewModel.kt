package dev.pocketledger

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.YearMonth
import java.util.UUID

data class LedgerUiState(
    val month: YearMonth = YearMonth.now(),
    val expenses: List<LocalExpense> = emptyList(),
    val budgetCents: Long = 200_000,
    val pendingCount: Int = 0,
    val endpoint: String = LedgerDatabase.DEFAULT_ENDPOINT,
    val syncing: Boolean = false,
    val saving: Boolean = false,
    val loading: Boolean = true,
    val dashboard: Dashboard? = null,
    val status: String = "Ready to track, even offline.",
    val error: String? = null
) {
    val asOf: LocalDate get() = when { month == YearMonth.now() -> LocalDate.now(); month.isBefore(YearMonth.now()) -> month.atEndOfMonth(); else -> month.atDay(1) }
    val monthExpenses get() = expenses.filter { YearMonth.from(it.expense.date) == month }
    val reportedExpenses get() = monthExpenses.filter { !it.expense.date.isAfter(asOf) }
    val spentCents get() = reportedExpenses.sumOf { it.expense.amountCents }
}

class LedgerViewModel(application: Application): AndroidViewModel(application) {
    private val database = LedgerDatabase(application)
    private val mutableState = MutableStateFlow(LedgerUiState())
    val state = mutableState.asStateFlow()
    init { viewModelScope.launch { reload() } }
    private suspend fun reload() {
        val month = mutableState.value.month
        val pair = withContext(Dispatchers.IO) { database.snapshot() to database.cachedDashboard(month.toString()) }
        mutableState.update { current ->
            if (current.month != month) current else current.copy(expenses = pair.first.expenses, budgetCents = pair.first.budgetCents, pendingCount = pair.first.pendingCount, endpoint = pair.first.endpoint, dashboard = pair.second, loading = false)
        }
    }
    fun moveMonth(delta: Long) {
        val month = mutableState.value.month.plusMonths(delta)
        if (month.year !in 2000..2100) return
        mutableState.update { it.copy(month = month, dashboard = null) }
        viewModelScope.launch { reload() }
    }
    fun clearError() { mutableState.update { it.copy(error = null) } }
    fun addExpense(amount: String, category: Category, note: String, date: String, onSaved: () -> Unit) {
        if (mutableState.value.saving) return
        mutableState.update { it.copy(saving = true) }
        viewModelScope.launch {
            try {
                val expense = Expense(UUID.randomUUID().toString(), Money.parseCents(amount), category, note.trim(), Expense.parseDate(date)).validate()
                withContext(Dispatchers.IO) { database.add(expense) }
                mutableState.update { it.copy(month = YearMonth.from(expense.date), status = "Expense saved on this device. Sync when you are ready.", error = null) }
                reload(); onSaved()
            } catch (error: kotlinx.coroutines.CancellationException) { throw error }
            catch (error: Exception) { mutableState.update { it.copy(error = error.message ?: "Could not save this expense.") } }
            finally { mutableState.update { it.copy(saving = false) } }
        }
    }
    fun deleteExpense(id: String) {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { database.delete(id) }
                mutableState.update { it.copy(status = "Expense deleted locally. The deletion is queued.", error = null) }; reload()
            } catch (error: kotlinx.coroutines.CancellationException) { throw error }
            catch (error: Exception) { mutableState.update { it.copy(error = error.message ?: "Could not delete expense.") } }
        }
    }
    fun saveConfiguration(budget: String, endpoint: String, onSaved: () -> Unit) {
        if (mutableState.value.syncing || mutableState.value.saving) return
        mutableState.update { it.copy(saving = true) }
        viewModelScope.launch {
            try {
                val cents = Money.parseCents(budget)
                HttpLedgerApi.normalizeEndpoint(endpoint)
                withContext(Dispatchers.IO) {
                    database.setEndpoint(endpoint)
                    if (database.snapshot().budgetCents != cents) database.setBudget(cents)
                }
                mutableState.update { it.copy(status = "Settings saved. Budget changes will sync with your expenses.", error = null) }
                reload(); onSaved()
            } catch (error: kotlinx.coroutines.CancellationException) { throw error }
            catch (error: Exception) { mutableState.update { it.copy(error = error.message ?: "Could not save settings.") } }
            finally { mutableState.update { it.copy(saving = false) } }
        }
    }
    fun sync() {
        if (mutableState.value.syncing || mutableState.value.loading || mutableState.value.saving) return
        val captured = mutableState.value
        mutableState.update { it.copy(syncing = true, error = null, status = "Sending queued changes…") }
        viewModelScope.launch {
            try {
                val outcome = withContext(Dispatchers.IO) {
                    SyncEngine(database, HttpLedgerApi(captured.endpoint)).sync(captured.month, captured.asOf).also { result -> result.dashboard?.let(database::cacheDashboard) }
                }
                mutableState.update { it.copy(status = outcome.warning ?: "Up to date. ${outcome.pushed} queued changes synced.") }
            } catch (error: kotlinx.coroutines.CancellationException) { throw error }
            catch (error: Exception) {
                mutableState.update { it.copy(status = "Sync paused · your remaining changes are saved on this device.", error = error.message ?: "The server could not be reached.") }
            } finally { mutableState.update { it.copy(syncing = false) }; reload() }
        }
    }
    override fun onCleared() { database.close(); super.onCleared() }
}
