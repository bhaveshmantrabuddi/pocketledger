package dev.pocketledger

object CsvExporter {
    private fun cell(value: String): String {
        val prefix = value.trimStart().firstOrNull()
        val safe = if (prefix != null && prefix in "=+-@") "'$value" else value
        return "\"${safe.replace("\"", "\"\"")}\""
    }
    fun export(expenses: List<Expense>): String {
        val header = "id,date,category,amount_cents,currency,note"
        val rows = expenses.sortedWith(compareBy<Expense> { it.date }.thenBy { it.id }).map { expense ->
            listOf(expense.id, expense.date.toString(), expense.category.key,
                expense.amountCents.toString(), "USD", expense.note).joinToString(",", transform = ::cell)
        }
        return (listOf(header) + rows).joinToString("\r\n", postfix = "\r\n")
    }
}
