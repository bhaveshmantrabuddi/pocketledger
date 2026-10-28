{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import BudgetEngine
import Control.Monad (forM_, unless)
import Data.Aeson (encode, object, (.=), Value(..))
import qualified Data.Aeson.KeyMap as KM
import Data.Either (isLeft)
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)

assert :: String -> Bool -> IO ()
assert name ok = unless ok (fail name)

assertInvalid :: String -> Value -> IO ()
assertInvalid name value = assert name (isLeft (parseRequest (encode value)))

expense :: Integer -> Expense
expense n = Expense "00000000-0000-0000-0000-000000000001" n "food" "" (fromGregorian 2024 2 1)

requestJSON :: [Value] -> Value
requestJSON txs = object ["month" .= ("2024-02" :: T.Text), "as_of" .= ("2024-02-01" :: T.Text),
  "monthly_limit_cents" .= (100 :: Integer), "transactions" .= txs]

transactionJSON :: T.Text -> Integer -> T.Text -> T.Text -> Value
transactionJSON ident amount date note = object ["id" .= ident,"amount_cents" .= amount,
  "category" .= ("food" :: T.Text),"note" .= note,"date" .= date]

main :: IO ()
main = do
  let base = Request 2024 2 (fromGregorian 2024 2 1) 100 [expense 101]
      s = calculate base
  assert "leap month / day-one projection / overspending" (daysInMonth s == 29 && projected s == 2929 && remaining s == -1 && dailyAllowance s == 0 && budgetStatus s == "over_budget")
  assert "cent ceiling" (projected (calculate (base {asOf = fromGregorian 2024 2 3, transactions = [expense 1]})) == 10)
  let lastDay = calculate (base {asOf = fromGregorian 2024 2 29, transactions = [expense 100]})
  assert "at budget month end" (daysRemaining lastDay == 0 && dailyAllowance lastDay == 0 && projected lastDay == 100 && budgetStatus lastDay == "at_budget")
  assert "century 2100 is not leap" (daysInMonth (calculate (Request 2100 2 (fromGregorian 2100 2 28) 100 [])) == 28)
  assert "empty transactions" (spent (calculate (base {transactions=[]})) == 0 && projected (calculate (base {transactions=[]})) == 0)
  assert "filter month and future" (spent (calculate (base {transactions=[expense 3,(expense 900) {expenseDate=fromGregorian 2024 2 2},(expense 800) {expenseDate=fromGregorian 2024 1 1}]})) == 3)
  let tx = transactionJSON "00000000-0000-0000-0000-000000000001" 100 "2024-02-01" ""
  assertInvalid "duplicate IDs rejected" (requestJSON [tx,tx])
  assertInvalid "invalid leap date rejected" (requestJSON [transactionJSON "00000000-0000-0000-0000-000000000001" 100 "2100-02-29" ""])
  assertInvalid "bad UUID rejected" (requestJSON [transactionJSON "bad" 100 "2024-02-01" ""])
  assertInvalid "money cap rejected" (requestJSON [transactionJSON "00000000-0000-0000-0000-000000000001" 100000001 "2024-02-01" ""])
  assertInvalid "Unicode code point limit" (requestJSON [transactionJSON "00000000-0000-0000-0000-000000000001" 100 "2024-02-01" (T.replicate 141 "\x1F600")])
  assert "trailing JSON rejected" (isLeft (parseRequest (encode (requestJSON []) <> "{}")))
  assert "unknown fields rejected" (isLeft (parseRequest "{\"extra\":1}"))
  let modified key value = case tx of
        Object o -> requestJSON [Object (KM.insert key value o)]
        _ -> requestJSON []
  assert "fractional cents rejected" (isLeft (parseRequest (encode (modified "amount_cents" (Number 1.25)))))
  assert "text cents rejected" (isLeft (parseRequest (encode (modified "amount_cents" (String "100")))))
  assert "unknown category rejected" (isLeft (parseRequest (encode (modified "category" (String "bank")))))
  assertInvalid "UUID identity is case insensitive" (requestJSON [
    transactionJSON "abcdef00-0000-0000-0000-000000000001" 1 "2024-02-01" "",
    transactionJSON "ABCDEF00-0000-0000-0000-000000000001" 1 "2024-02-01" ""])
  assert "valid 140 supplementary code points" (not (isLeft (parseRequest (encode (modified "note" (String (T.replicate 140 "\x1F600")))))))
  let numericRequest token = BLC.pack ("{\"month\":\"2024-02\",\"as_of\":\"2024-02-01\",\"monthly_limit_cents\":100,\"transactions\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"amount_cents\":" ++ token ++ ",\"category\":\"food\",\"note\":\"price 1.5e2 and \\\"quoted\\\"\",\"date\":\"2024-02-01\"}]}")
  forM_ ["1.0","1e0","1e2","1.0000000000000000001"] $ \token ->
    assert "noninteger wire syntax rejected before numeric normalization" (isLeft (parseRequest (numericRequest token)))
  assert "decimal/exponent text in escaped quoted notes remains valid" (not (isLeft (parseRequest (numericRequest "1"))))
  -- Generated arithmetic properties over 28/29/30/31-day months and reporting days.
  forM_ [(2023,2),(2024,2),(2024,4),(2024,10)] $ \(year,month) ->
    forM_ [1..28] $ \day -> forM_ [0,1,2,99,100,100000000,100000000000000000000] $ \n -> do
      let r = Request year month (fromGregorian year month day) 100 [(expense n) {expenseDate=fromGregorian year month 1}]
          result = calculate r
          p = projected result; d = toInteger day; count = daysInMonth result
      assert "projection is exact ceiling" (p*d >= n*count && (n == 0 || (p-1)*d < n*count))
      assert "remaining conserves exact cents" (remaining result + spent result == 100)
      assert "allowance is nonnegative" (dailyAllowance result >= 0)
  putStrLn "budget-tests: boundary, validation and 784 generated arithmetic cases passed"
