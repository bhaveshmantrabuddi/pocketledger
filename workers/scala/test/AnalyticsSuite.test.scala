package pocketledger

import java.time.{LocalDate, YearMonth}
import ujson.{Arr, Obj, Str}

class AnalyticsSuite extends munit.FunSuite {
  def id(n: Int): String = f"00000000-0000-0000-0000-$n%012d"
  def expense(n: Int, amount: Long = 100, category: String = "food", day: Int = 1): Expense =
    Expense(id(n), amount, category, "", LocalDate.of(2024, 2, day))
  def request(rows: Vector[Expense] = Vector.empty): Request = Request(YearMonth.of(2024, 2), LocalDate.of(2024, 2, 29), 1000, rows)
  def tx(n: Int = 1): Obj = Obj("id" -> id(n), "amount_cents" -> 100, "category" -> "food", "note" -> "", "date" -> "2024-02-01")
  def json(rows: Seq[Obj] = Seq.empty): Obj = Obj("month" -> "2024-02", "as_of" -> "2024-02-29", "monthly_limit_cents" -> 1000, "transactions" -> Arr.from(rows))
  def invalid(value: Obj): Unit = intercept[Exception](Engine.parse(ujson.write(value)))

  test("zero-fill every completed day including leap day") {
    val result = Engine.calculate(request())
    assertEquals(result.daily.length, 29)
    assertEquals(result.daily.last.date.toString, "2024-02-29")
    assert(result.daily.forall(_.spent == 0))
    assert(result.categories.isEmpty && result.largest.isEmpty)
  }
  test("category amount ties use name; largest ties use date then ID") {
    val rows = Vector(expense(3, 200, "food", 2), expense(2, 200, "health", 1), expense(1, 200, "health", 1), expense(4, 200, "food", 1))
    val result = Engine.calculate(request(rows))
    assertEquals(result.categories.map(_.category), Vector("food", "health"))
    assertEquals(result.largest.map(_.id), Vector(id(1), id(2), id(4), id(3)))
  }
  test("filter before top-five and aggregate; ignore future and other months") {
    val rows = (1 to 10).map(n => expense(n, n * 100)).toVector ++ Vector(expense(11).copy(date=LocalDate.of(2024, 3, 1)), expense(12, 99999, day=20))
    val result = Engine.calculate(request(rows).copy(asOf=LocalDate.of(2024, 2, 10)))
    assertEquals(result.largest.map(_.amount), Vector(1000L,900L,800L,700L,600L))
    assertEquals(result.categories.head.spent, 5500L)
    assertEquals(result.daily.length, 10)
  }
  test("independent schema and boundary validation") {
    val bad = Vector[Obj](
      tx().tap(o => o("id") = "bad"), tx().tap(o => o("amount_cents") = 0),
      tx().tap(o => o("amount_cents") = 100000001), tx().tap(o => o("amount_cents") = 1.5),
      tx().tap(o => o("category") = "bank"), tx().tap(o => o("date") = "2100-02-29"),
      tx().tap(o => o("date") = "2024-02-30"), tx().tap(o => o("note") = "x" * 141),
      tx().tap(o => o("extra") = true)
    )
    bad.foreach(o => invalid(json(Seq(o))))
    invalid(json(Seq(tx(),tx())))
    val lower = tx().tap(o => o("id") = "abcdef00-0000-0000-0000-000000000001")
    val upper = tx().tap(o => o("id") = "ABCDEF00-0000-0000-0000-000000000001")
    invalid(json(Seq(lower,upper)))
    assertEquals(Engine.parse(ujson.write(json(Seq(upper)))).transactions.head.id,"abcdef00-0000-0000-0000-000000000001")
    invalid(json().tap(o => o("as_of") = "2024-03-01"))
    invalid(json().tap(o => o("monthly_limit_cents") = 0))
    intercept[Exception](Engine.parse(ujson.write(json()) + "{}"))
  }
  test("Unicode uses code points, and cents at cap are accepted") {
    val o = tx().tap(o => {o("note") = "😀" * 140; o("amount_cents") = 100000000})
    assertEquals(Engine.parse(ujson.write(json(Seq(o)))).transactions.head.note.codePointCount(0,280),140)
    invalid(json(Seq(o.tap(o => o("note") = "😀" * 141))))
  }
  test("wire numbers reject normalization and rounding; quoted text is preserved") {
    val raw = ujson.write(json(Seq(tx())))
    for (literal <- Seq("1.0", "1e0", "1e2", "1.0000000000000000001")) {
      intercept[IllegalArgumentException](Engine.parse(raw.replace("\"amount_cents\":100",s"\"amount_cents\":$literal")))
    }
    val note = "price 1.5e2 and \\" + "\"quoted\""
    val value = json(Seq(tx().tap(o => o("note") = note)))
    assertEquals(Engine.parse(ujson.write(value)).transactions.head.note,note)
  }
  test("overflow raises an error; encoder does not round large Long totals") {
    intercept[IllegalArgumentException](Engine.checkedAdd(Long.MaxValue, 1L))
    intercept[IllegalArgumentException](Engine.calculate(request(Vector(expense(1,Long.MaxValue),expense(2,1L)))))
    val precise = 9007199254740993L
    val encoded = Engine.encode(Analytics(Vector(Category("food", precise, 1)),Vector.empty,Vector.empty))
    assert(encoded.contains("\"spent_cents\":9007199254740993"))
  }
  test("generated conservation, order invariance and deterministic top five") {
    val random = new scala.util.Random(421)
    for (trial <- 0 until 300) {
      val rows = (1 to random.nextInt(80)).map(n => expense(n, 1L + random.nextInt(100000000), if (n % 2 == 0) "food" else "health", 1 + random.nextInt(29))).toVector
      val result = Engine.calculate(request(rows))
      val reverse = Engine.calculate(request(rows.reverse))
      assertEquals(result, reverse)
      assertEquals(result.categories.map(_.spent).sum, rows.map(_.amount).sum)
      assertEquals(result.daily.map(_.spent).sum, rows.map(_.amount).sum)
      assertEquals(result.categories.map(_.count).sum, rows.length.toLong)
      assertEquals(result.largest.length, math.min(5,rows.length))
    }
  }

  extension [A](a: A) private def tap(f: A => Unit): A = {f(a); a}
}
