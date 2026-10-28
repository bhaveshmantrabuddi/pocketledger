package dev.pocketledger

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.time.LocalDate
import java.time.YearMonth

object JsonCodec {
    private fun JSONObject.integer(key: String): Long {
        val value = get(key)
        require(value is Int || value is Long) { "Server field $key must be an integer." }
        return (value as Number).toLong()
    }
    fun expenseJson(expense: Expense) = JSONObject().put("id", expense.id).put("amount_cents", expense.amountCents).put("category", expense.category.key).put("note", expense.note).put("date", expense.date.toString())
    fun expense(json: JSONObject) = Expense(json.getString("id"), json.integer("amount_cents"), Category.fromKey(json.getString("category")), json.getString("note"), Expense.parseDate(json.getString("date"))).validate()
    fun budget(json: JSONObject): Long {
        require(json.getString("currency") == "USD") { "Only USD is supported." }
        return json.integer("monthly_limit_cents").also { require(it in 1..Money.MAX_CENTS) { "Invalid server budget." } }
    }
    fun dashboard(json: JSONObject): Dashboard {
        require(json.getString("currency") == "USD") { "Only USD is supported." }
        val sources = json.getJSONObject("calculation_sources")
        require(sources.getString("summary") == "haskell" && sources.getString("analytics") == "scala") { "Unexpected calculation source." }
        val summary = json.getJSONObject("summary")
        val categories = json.getJSONObject("analytics").getJSONArray("categories")
        return Dashboard(json.getString("month"), json.getString("as_of"), json.integer("monthly_limit_cents"), BudgetSummary(summary.integer("spent_cents"), summary.integer("remaining_cents"), summary.integer("projected_cents"), summary.integer("daily_allowance_cents"), summary.getString("status")),
            List(categories.length()) { i -> val category = categories.getJSONObject(i); CategoryTotal(Category.fromKey(category.getString("category")), category.integer("spent_cents"), category.getInt("count")) })
    }
    fun dashboardJson(value: Dashboard) = JSONObject().put("month", value.month).put("as_of", value.asOf).put("currency", "USD").put("monthly_limit_cents", value.monthlyLimitCents)
        .put("summary", JSONObject().put("spent_cents", value.summary.spentCents).put("remaining_cents", value.summary.remainingCents).put("projected_cents", value.summary.projectedCents).put("daily_allowance_cents", value.summary.dailyAllowanceCents).put("status", value.summary.status))
        .put("analytics", JSONObject().put("categories", JSONArray().also { array -> value.categories.forEach { array.put(JSONObject().put("category", it.category.key).put("spent_cents", it.spentCents).put("count", it.count)) } }))
        .put("calculation_sources", JSONObject().put("summary", "haskell").put("analytics", "scala"))
}

class HttpLedgerApi(endpoint: String): LedgerApi {
    private val base = normalizeEndpoint(endpoint)
    private suspend fun request(method: String, path: String, body: JSONObject? = null): JSONObject? = withContext(Dispatchers.IO) {
        val connection = URI(base + path).toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 6_000; connection.readTimeout = 10_000
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) {
                connection.doOutput = true; connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val bytes = stream?.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (output.size() <= 2_000_000) {
                    val read = input.read(buffer, 0, minOf(buffer.size, 2_000_001 - output.size()))
                    if (read < 0) break
                    output.write(buffer, 0, read)
                }
                output.toByteArray()
            } ?: byteArrayOf()
            if (bytes.size > 2_000_000) throw IOException("Server response is too large.")
            val text = bytes.toString(Charsets.UTF_8)
            if (status !in 200..299) {
                val message = runCatching { JSONObject(text).getString("error") }.getOrDefault("HTTP $status")
                throw IOException(message)
            }
            if (text.isBlank()) null else JSONObject(text)
        } finally { connection.disconnect() }
    }
    override suspend fun create(expense: Expense) { request("POST", "/v1/transactions", JsonCodec.expenseJson(expense.validate())) }
    override suspend fun delete(id: String) { request("DELETE", "/v1/transactions/$id") }
    override suspend fun setBudget(cents: Long) { require(cents in 1..Money.MAX_CENTS); request("PUT", "/v1/budget", JSONObject().put("monthly_limit_cents", cents)) }
    override suspend fun expenses(): List<Expense> {
        val array = requireNotNull(request("GET", "/v1/transactions")).getJSONArray("transactions")
        return List(array.length()) { JsonCodec.expense(array.getJSONObject(it)) }
    }
    override suspend fun budget() = JsonCodec.budget(requireNotNull(request("GET", "/v1/budget")))
    override suspend fun dashboard(month: YearMonth, asOf: LocalDate) = JsonCodec.dashboard(requireNotNull(request("GET", "/v1/dashboard?month=$month&as_of=$asOf")))
    companion object {
        fun normalizeEndpoint(input: String): String {
            val value = input.trim().trimEnd('/')
            val uri = runCatching { URI(value) }.getOrElse { throw IllegalArgumentException("Enter a valid HTTP or HTTPS server URL.") }
            require(uri.scheme in listOf("http", "https") && !uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null && uri.path.orEmpty().isEmpty() && uri.port in -1..65535) { "Use a server origin, such as http://10.0.2.2:8080, with no credentials or path." }
            return value
        }
    }
}
