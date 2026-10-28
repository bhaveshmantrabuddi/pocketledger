package pocketledger

import java.nio.charset.StandardCharsets
import java.time.{LocalDate, YearMonth}
import scala.util.control.NonFatal
import ujson.{Arr, Num, Obj, Str, Value}

final case class Expense(id: String, amount: Long, category: String, note: String, date: LocalDate)
final case class Request(month: YearMonth, asOf: LocalDate, limit: Long, transactions: Vector[Expense])
final case class Category(category: String, spent: Long, count: Long)
final case class Daily(date: LocalDate, spent: Long)
final case class Analytics(categories: Vector[Category], daily: Vector[Daily], largest: Vector[Expense])

object Engine {
  private val categories = Set("food", "transport", "housing", "shopping", "health", "entertainment", "other")
  private val uuid = "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}".r
  private def reject(message: String): Nothing = throw new IllegalArgumentException(message)

  private def fields(value: Value, expected: Set[String], context: String): Obj = value match {
    case obj: Obj if obj.obj.keySet.toSet == expected => obj
    case _: Obj => reject(s"$context has missing or unknown fields")
    case _ => reject(s"$context must be an object")
  }
  private def text(obj: Obj, name: String): String = obj(name) match {
    case Str(s) => s
    case _ => reject(s"$name must be a string")
  }
  private def money(obj: Obj, name: String): Long = obj(name) match {
    case Num(n) if n.isWhole && n >= 1 && n <= 100000000 => n.toLong
    case _ => reject(s"$name must be an integer from 1 through 100000000 cents")
  }
  private def date(raw: String): LocalDate = {
    if (!raw.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")) reject("date must be Gregorian YYYY-MM-DD")
    val d = try LocalDate.parse(raw) catch { case NonFatal(_) => reject("invalid Gregorian date") }
    if (d.getYear < 2000 || d.getYear > 2100) reject("date year must be within 2000..2100")
    d
  }

  // ujson represents JSON numbers as Double, so reject noninteger wire syntax
  // before parsing can round a tiny fraction. Quoted/escaped text is skipped.
  private def integerTokens(json: String): Unit = {
    var i = 0
    var quoted = false
    var escaped = false
    while (i < json.length) {
      val c = json.charAt(i)
      if (quoted) {
        if (escaped) escaped = false
        else if (c == '\\') escaped = true
        else if (c == '"') quoted = false
        i += 1
      } else if (c == '"') { quoted = true; i += 1 }
      else if (c == '-' || (c >= '0' && c <= '9')) {
        val start = i
        while (i < json.length && ("0123456789.eE+-".indexOf(json.charAt(i)) >= 0)) i += 1
        val token = json.substring(start, i)
        if (token.exists(ch => ch == '.' || ch == 'e' || ch == 'E'))
          reject("money must use integer JSON literals without decimal points or exponents")
      } else i += 1
    }
  }

  def parse(json: String): Request = {
    integerTokens(json)
    val obj = fields(ujson.read(json), Set("month", "as_of", "monthly_limit_cents", "transactions"), "request")
    val rawMonth = text(obj, "month")
    if (!rawMonth.matches("[0-9]{4}-[0-9]{2}")) reject("month must be YYYY-MM")
    val first = date(rawMonth + "-01")
    val month = YearMonth.from(first)
    val asOf = date(text(obj, "as_of"))
    if (YearMonth.from(asOf) != month) reject("as_of must fall within month")
    val limit = money(obj, "monthly_limit_cents")
    val rows = obj("transactions") match {
      case values: Arr => values.value.toVector
      case _ => reject("transactions must be an array")
    }
    val seen = scala.collection.mutable.HashSet.empty[String]
    val expenses = rows.map { value =>
      val tx = fields(value, Set("id", "amount_cents", "category", "note", "date"), "transaction")
      val id = text(tx, "id")
      if (!uuid.matches(id)) reject("transaction id must be a UUID")
      if (!seen.add(id.toLowerCase(java.util.Locale.ROOT))) reject("duplicate transaction id")
      val amount = money(tx, "amount_cents")
      val category = text(tx, "category")
      if (!categories(category)) reject("unknown transaction category")
      val note = text(tx, "note")
      if (note.codePointCount(0, note.length) > 140) reject("note exceeds 140 Unicode code points")
      Expense(id.toLowerCase(java.util.Locale.ROOT), amount, category, note, date(text(tx, "date")))
    }
    Request(month, asOf, limit, expenses)
  }

  def checkedAdd(a: Long, b: Long): Long = try Math.addExact(a, b)
    catch { case _: ArithmeticException => reject("analytics integer overflow") }

  def calculate(request: Request): Analytics = {
    val filtered = request.transactions.filter(e => YearMonth.from(e.date) == request.month && !e.date.isAfter(request.asOf))
    val categories = filtered.groupBy(_.category).iterator.map { case (name, expenses) =>
      Category(name, expenses.foldLeft(0L)((sum, e) => checkedAdd(sum, e.amount)), expenses.length.toLong)
    }.toVector.sortWith((a, b) => if (a.spent != b.spent) a.spent > b.spent else a.category < b.category)
    val byDay = filtered.groupMapReduce(_.date)(_.amount)(checkedAdd)
    val daily = Vector.tabulate(request.asOf.getDayOfMonth) { i =>
      val d = request.month.atDay(i + 1)
      Daily(d, byDay.getOrElse(d, 0L))
    }
    val largest = filtered.sortWith { (a, b) =>
      if (a.amount != b.amount) a.amount > b.amount
      else if (a.date != b.date) a.date.isBefore(b.date)
      else a.id < b.id
    }.take(5)
    Analytics(categories, daily, largest)
  }

  // ujson stores numbers as Double. Emit validated Long totals as JSON numeric
  // literals directly, preserving exact integer cents even above 2^53.
  def encode(result: Analytics): String = {
    def quote(s: String): String = ujson.write(Str(s))
    val cats = result.categories.map(c => s"{\"category\":${quote(c.category)},\"spent_cents\":${c.spent},\"count\":${c.count}}").mkString("[", ",", "]")
    val days = result.daily.map(d => s"{\"date\":${quote(d.date.toString)},\"spent_cents\":${d.spent}}").mkString("[", ",", "]")
    val largest = result.largest.map(e => s"{\"id\":${quote(e.id)},\"amount_cents\":${e.amount},\"category\":${quote(e.category)},\"note\":${quote(e.note)},\"date\":${quote(e.date.toString)}}").mkString("[", ",", "]")
    s"{\"categories\":$cats,\"daily\":$days,\"largest\":$largest}"
  }
}

object Main {
  def main(args: Array[String]): Unit = {
    try {
      val maxBytes = 16 * 1024 * 1024
      val bytes = System.in.readNBytes(maxBytes + 1)
      if (bytes.length > maxBytes) throw new IllegalArgumentException("input exceeds 16 MiB")
      val decoder = StandardCharsets.UTF_8.newDecoder()
      val raw = decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString
      val result = Engine.calculate(Engine.parse(raw))
      System.out.write((Engine.encode(result) + "\n").getBytes(StandardCharsets.UTF_8))
      System.out.flush()
    } catch {
      case NonFatal(e) =>
        System.err.println("analytics: " + Option(e.getMessage).getOrElse(e.getClass.getSimpleName))
        System.exit(1)
    }
  }
}
