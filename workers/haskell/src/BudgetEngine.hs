{-# LANGUAGE OverloadedStrings #-}
module BudgetEngine
  ( Expense(..), Request(..), Summary(..), parseRequest, calculate, summaryJSON ) where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Char (isHexDigit)
import Data.List (foldl')
import Data.Scientific (Scientific, floatingOrInteger)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)

data Expense = Expense
  { expenseId :: Text, expenseAmount :: Integer, expenseCategory :: Text
  , expenseNote :: Text, expenseDate :: Day } deriving (Eq, Show)
data Request = Request
  { reportYear :: Integer, reportMonth :: Int, asOf :: Day
  , monthlyLimit :: Integer, transactions :: [Expense] } deriving (Eq, Show)
data Summary = Summary
  { spent :: Integer, remaining :: Integer, elapsedDays :: Integer
  , daysInMonth :: Integer, daysRemaining :: Integer, projected :: Integer
  , dailyAllowance :: Integer, budgetStatus :: Text } deriving (Eq, Show)

exactFields :: [Text] -> Object -> Parser ()
exactFields names obj = unless (Set.fromList names == Set.fromList (map Key.toText (KM.keys obj)))
  (fail "missing or unknown object fields")

money :: Scientific -> Parser Integer
money value
  | value < 1 || value > 100000000 = fail "money must be an integer from 1 through 100000000 cents"
  | otherwise = case floatingOrInteger value :: Either Double Integer of
      Right n -> pure n
      _ -> fail "money must be an integer from 1 through 100000000 cents"

validUUID :: Text -> Bool
validUUID value = let s = T.unpack value in length s == 36 &&
  and [if i `elem` [8,13,18,23] then c == '-' else isHexDigit c | (i,c) <- zip [0 :: Int ..] s]

parseDay :: Text -> Parser Day
parseDay value = do
  let s = T.unpack value
  when (length s /= 10 || any (\(i,c) -> if i `elem` [4,7] then c /= '-' else c < '0' || c > '9') (zip [0 :: Int ..] s))
    (fail "date must be Gregorian YYYY-MM-DD")
  case parseTimeM True defaultTimeLocale "%Y-%m-%d" s :: Maybe Day of
    Just d | let (y,_,_) = toGregorian d, y >= 2000 && y <= 2100,
             formatTime defaultTimeLocale "%Y-%m-%d" d == s -> pure d
    _ -> fail "date is invalid or outside years 2000..2100"

instance FromJSON Expense where
  parseJSON = withObject "transaction" $ \o -> do
    exactFields ["id","amount_cents","category","note","date"] o
    ident <- o .: "id"
    unless (validUUID ident) (fail "transaction id must be a UUID")
    amount <- o .: "amount_cents" >>= money
    category <- o .: "category"
    unless (category `elem` ["food","transport","housing","shopping","health","entertainment","other"])
      (fail "unknown transaction category")
    note <- o .: "note"
    when (T.length note > 140) (fail "note exceeds 140 Unicode code points")
    day <- o .: "date" >>= parseDay
    pure (Expense (T.toLower ident) amount category note day)

instance FromJSON Request where
  parseJSON = withObject "worker request" $ \o -> do
    exactFields ["month","as_of","monthly_limit_cents","transactions"] o
    month <- o .: "month"
    when (T.length month /= 7) (fail "month must be YYYY-MM")
    first <- parseDay (month <> "-01")
    day <- o .: "as_of" >>= parseDay
    let (year, monthNumber, _) = toGregorian first
        (ay, am, _) = toGregorian day
    unless (year == ay && monthNumber == am) (fail "as_of must be within month")
    limit <- o .: "monthly_limit_cents" >>= money
    expenses <- o .: "transactions"
    let ids = map expenseId expenses
    unless (length ids == Set.size (Set.fromList ids)) (fail "duplicate transaction id")
    pure (Request year monthNumber day limit expenses)

parseRequest :: BL.ByteString -> Either String Request
parseRequest raw = integerTokens (BLC.unpack raw) >> eitherDecode raw

-- Preserve the wire's integer-only syntax before Scientific normalizes 1.0 or
-- 1e0. ASCII quote/escape scanning leaves arbitrary UTF-8 note text untouched.
integerTokens :: String -> Either String ()
integerTokens = go False False
  where
    digit c = c >= '0' && c <= '9'
    number c = digit c || c `elem` (".eE+-" :: String)
    go _ _ [] = Right ()
    go True escaped (c:rest)
      | escaped = go True False rest
      | c == '\\' = go True True rest
      | c == '"' = go False False rest
      | otherwise = go True False rest
    go False _ (c:rest)
      | c == '"' = go True False rest
      | c == '-' || digit c =
          let (token, remainingInput) = span number (c:rest)
          in if any (`elem` (".eE" :: String)) token
             then Left "money must use integer JSON literals without decimal points or exponents"
             else go False False remainingInput
      | otherwise = go False False rest

-- Parsing is the validation boundary. Integer keeps sums and products exact.
calculate :: Request -> Summary
calculate request = Summary total left elapsed dim future pace allowance status
  where
    selected e = let (y,m,_) = toGregorian (expenseDate e) in
      y == reportYear request && m == reportMonth request && expenseDate e <= asOf request
    total = foldl' (\acc e -> if selected e then acc + expenseAmount e else acc) 0 (transactions request)
    left = monthlyLimit request - total
    (_,_,elapsedInt) = toGregorian (asOf request)
    elapsed = toInteger elapsedInt
    dim = toInteger (gregorianMonthLength (reportYear request) (reportMonth request))
    future = dim - elapsed
    pace = (total * dim + elapsed - 1) `div` elapsed
    allowance = if future == 0 then 0 else max 0 left `div` future
    status | total < monthlyLimit request = "under_budget"
           | total == monthlyLimit request = "at_budget"
           | otherwise = "over_budget"

summaryJSON :: Summary -> Value
summaryJSON s = object
  [ "spent_cents" .= spent s, "remaining_cents" .= remaining s
  , "elapsed_days" .= elapsedDays s, "days_in_month" .= daysInMonth s
  , "days_remaining" .= daysRemaining s, "projected_cents" .= projected s
  , "daily_allowance_cents" .= dailyAllowance s, "status" .= budgetStatus s ]
