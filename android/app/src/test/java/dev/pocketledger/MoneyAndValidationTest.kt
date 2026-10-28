package dev.pocketledger

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class MoneyAndValidationTest {
    @Test fun decimalInputUsesExactCents() {
        assertEquals(1L, Money.parseCents("0.01"))
        assertEquals(120L, Money.parseCents("1.2"))
        assertEquals(123L, Money.parseCents("1.23"))
        assertEquals(100_000_000L, Money.parseCents("1000000.00"))
    }
    @Test fun excessPrecisionAndNonDecimalSyntaxAreRejected() {
        listOf("1.001", "0.000", "1e2", "+1", "-1", "1,000.00", "$5", ".50", "1.", "NaN", "01.00").forEach { input ->
            assertThrows("Should reject $input", IllegalArgumentException::class.java) { Money.parseCents(input) }
        }
    }
    @Test fun boundsRejectZeroAndOversizedAmounts() {
        listOf("0", "0.00", "1000000.01", "9999999", "9999999999999999999999").forEach { input -> assertThrows(IllegalArgumentException::class.java) { Money.parseCents(input) } }
    }
    @Test fun centsFormatWithoutFloatingPointRounding() {
        assertEquals("$1,234.56", Money.format(123456))
        assertEquals("−$0.01", Money.format(-1))
        assertEquals("0.01", Money.input(1))
        assertEquals("1000000.00", Money.input(Money.MAX_CENTS))
    }
    @Test fun calendarValidationHandlesLeapDaysAndYearLimits() {
        assertEquals(LocalDate.of(2024, 2, 29), Expense.parseDate("2024-02-29"))
        listOf("2023-02-29", "2024-2-29", "1999-12-31", "2101-01-01", "2026-04-31").forEach { date -> assertThrows(IllegalArgumentException::class.java) { Expense.parseDate(date) } }
    }
    @Test fun notesUseUnicodeCodePointsAndIdsRequireCanonicalShape() {
        val valid = Expense("b5a5bd60-4cec-4297-af3a-c980b7c3b97b", 1250, Category.FOOD, "🍋".repeat(140), LocalDate.of(2026, 10, 27))
        valid.validate()
        assertThrows(IllegalArgumentException::class.java) { valid.copy(note = "🍋".repeat(141)).validate() }
        assertThrows(IllegalArgumentException::class.java) { valid.copy(id = "1-1-1-1-1").validate() }
    }
}
