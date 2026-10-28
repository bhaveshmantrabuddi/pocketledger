package dev.pocketledger

import java.time.LocalDate
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class CsvExporterTest {
    private fun record(note: String) = Expense(UUID.randomUUID().toString(), 1234, Category.FOOD, note, LocalDate.of(2026, 10, 27))
    @Test fun quotesCommasNewlinesAndUnicode() {
        val result = CsvExporter.export(listOf(record("Café, \"tea\"\nLunch")))
        assertTrue(result.contains("\"Café, \"\"tea\"\"\nLunch\""))
        assertTrue(result.contains("\"1234\",\"USD\""))
    }
    @Test fun escapesSpreadsheetFormulaPrefixes() {
        for (note in listOf("=1+1", " +SUM(A1)", "-5", "@function")) {
            assertTrue(CsvExporter.export(listOf(record(note))).contains("\"'$note\""))
        }
    }
    @Test fun emptyExportContainsHeader() {
        assertEquals("id,date,category,amount_cents,currency,note\r\n", CsvExporter.export(emptyList()))
    }
}
