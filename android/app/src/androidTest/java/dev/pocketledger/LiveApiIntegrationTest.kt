package dev.pocketledger

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
import java.time.LocalDate
import java.time.YearMonth
import java.util.UUID

/** Opt-in, disposable-server wire test. Does not touch the app's SQLite ledger. */
@RunWith(AndroidJUnit4::class)
class LiveApiIntegrationTest {
    @Test fun realServerSupportsReplayConflictBudgetAndWorkerDashboard() = runBlocking {
        val endpoint = InstrumentationRegistry.getArguments().getString("pocketledger.testServer")
        assumeTrue("Pass pocketledger.testServer to target a disposable Go API with real workers.", !endpoint.isNullOrBlank())
        val api = HttpLedgerApi(requireNotNull(endpoint))
        val month = YearMonth.of(2026, 10)
        val asOf = LocalDate.of(2026, 10, 27)
        val row = Expense(UUID.randomUUID().toString(), 1250, Category.FOOD, "Synthetic Android wire test", asOf)
        val originalBudget = api.budget()
        try {
            api.create(row); api.create(row)
            assertEquals(1, api.expenses().count { it.id == row.id })
            val conflict = runCatching { api.create(row.copy(amountCents = 1300)) }.exceptionOrNull()
            assertTrue("A different payload with the same ID must conflict.", conflict is IOException)
            assertEquals(1250L, api.expenses().single { it.id == row.id }.amountCents)
            api.setBudget(123_456); api.setBudget(123_456)
            assertEquals(123_456L, api.budget())
            val expectedSpent = api.expenses().filter { YearMonth.from(it.date) == month && !it.date.isAfter(asOf) }.sumOf { it.amountCents }
            // JsonCodec also requires calculation_sources={summary:haskell,analytics:scala}.
            val dashboard = api.dashboard(month, asOf)
            assertEquals(expectedSpent, dashboard.summary.spentCents)
            assertEquals(123_456L - expectedSpent, dashboard.summary.remainingCents)
            assertEquals((expectedSpent * 31L + 26L) / 27L, dashboard.summary.projectedCents)
            assertTrue(dashboard.categories.any { it.category == Category.FOOD && it.spentCents >= row.amountCents })
            api.delete(row.id); api.delete(row.id)
            assertFalse(api.expenses().any { it.id == row.id })
        } finally {
            runCatching { api.delete(row.id) }
            runCatching { api.setBudget(originalBudget) }
        }
    }
}
