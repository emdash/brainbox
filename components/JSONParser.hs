{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

-- | Parser for "legacy" JSON-based recurrences.
--
-- We use Text.JSON because we don't need sophisticated JSON
-- marshalling.
module JSONParser (JExpr(..), fromJSON, parseDT, simplify) where

import Data.Ratio
import Text.JSON
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time.Clock
import Data.Time.Calendar
import Data.Time.Format.ISO8601
import Data.Time.LocalTime
import Text.Parse

import Interval (DateTime, TimeDelta)
import qualified Interval as Interval
import DateSet
import qualified Parser

-- | A simpler JSON representation for easier pattern matching.
--
-- We don't need general [de]serialization, we just need to support
-- the JSON-based language for date expressions, and only until I can
-- finish writing a custom parser, and migrate the existing patterns
-- to the new language.
data JExpr
  = Null
  | I Int
  | F Double
  | B Bool
  | S String
  | A [JExpr]
  | O [(String, JExpr)]
  deriving (Eq, Ord, Show)

-- | Convert text.json to our notation.
simplify :: JSValue -> JExpr
simplify JSNull = Null
simplify (JSBool b) = B b
simplify (JSRational True v) = F $ fromRational v
simplify (JSRational False v) = case denominator v of
  1 -> I $ round v
  _ -> F $ fromRational v
simplify (JSString v) = S $ fromJSString v
simplify (JSArray v) = A $ simplify <$> v
simplify (JSObject v) = O $ mapField <$> fromJSObject v
  where
    mapField (key, value) = (key, simplify value)

-- XXX: This is an orphan instance, but hey it seems to work.
instance MonadFail (Either String) where
  fail = Left

-- | Parse a snippet of JSON into a time delta, using our custom
-- notation and allowing for addition and subtraction of time intervals.
parseDuration :: JExpr -> Either String TimeDelta
parseDuration (S d) = fst $ runParser Parser.parseDuration d
parseDuration (A [S "+", a, b]) = do
  a <- parseDuration a
  b <- parseDuration b
  return $ a + b
parseDuration (A [S "-", a, b]) = do
  a <- parseDuration a
  b <- parseDuration b
  return $ a - b
parseDuration e     = Left $ "Invalid duration: " ++ show e

-- | Parse a day abbreviation from a snippet of JSON.
--
-- XXX: Python weekdays set monday as 0, whereas the `time` package
-- sets monday at 1. Watch out!!
parseDay :: JExpr -> Either String DayOfWeek
parseDay (S day) = fst $ runParser Parser.parseDay day
parseDay (I day) = if 0 <= day && day <= 6
                    then return $ toEnum $ mod (day + 1) 7
                    else Left $ "Invalid weekday: " ++ show day
parseDay err     = Left $ "Invalid weekday: " ++ show err

-- | Parse a month abbreviation from a string.
parseMonth :: JExpr -> Either String MonthOfYear
parseMonth (S mon) = fst $ runParser Parser.parseMonth mon
parseMonth (I mon) = if 1 <= mon && mon <= 12
  then return $ mon
  else Left $ "Invalid month: " ++ show mon
parseMonth err     = Left $ "Invalid month: " ++ show err

parseDT :: JExpr -> Either String DateTime
parseDT (S date) = case iso8601ParseM date of
  Left _ -> case iso8601ParseM date :: Either String Day of
    Right day -> Right $ UTCTime day (fromInteger 0)
    Left _ -> fst $ runParser Parser.parseDateTime date
  success -> success
parseDT e = Left $ "Invalid datetime: " ++ show e

parseTime :: JExpr -> Either String TimeOfDay
parseTime (S time) = do
  case iso8601ParseM time of
    Left _ -> fst $ runParser Parser.parseTimeOfDay time
    success -> success
parseTime (I hour) = if 0 <= hour && hour <= 23
  then Right $ TimeOfDay hour 0 0
  else Left $ "Invalid hour: " ++ show hour
parseTime (A [S "+", a, b]) = do
  a <- parseTime a
  b <- parseDuration b
  case timeToDaysAndTimeOfDay $ (daysAndTimeOfDayToTime 0 a) + b of
    (0, time_) -> return time_
    (_, _)     -> Left $ "Time overflow: " ++ show b
parseTime (A [S "-", a, b]) = do
  a <- parseTime a
  b <- parseDuration b
  case timeToDaysAndTimeOfDay $ (daysAndTimeOfDayToTime 0 a) - b of
    (0, time_) -> return time_
    (_, _)     -> Left $ "Time overflow: " ++ show b
parseTime e = Left $ "Invalid time of day: " ++ show e

parseDayOfMonth :: JExpr -> Either String DayOfMonth
parseDayOfMonth (I d) = case d >= 1 && d <= 31 of
  True  -> Right d
  False -> Left $ "Invalid day of month: " ++ show d
parseDayOfMonth e = Left $ "Invalid day of month: " ++ show e

parseDays :: [JExpr] -> Either String (Set DayOfMonth)
parseDays [start, S "-", end] = do
  start <- parseDayOfMonth start
  end   <- parseDayOfMonth end
  return $ Set.fromList [start .. end]
parseDays days = do
  days <- traverse parseDayOfMonth days
  return $ Set.fromList days

-- | Entry point for parsing "legacy" JSON datetime expressions.
fromJSON :: JExpr -> Either String DateSet
fromJSON (A ((S "dates") : dates)) = do
  dates' <- traverse parseDT dates
  return $ Explicit $ Set.fromList $ Interval.fromDate' <$> dates'
fromJSON (A [S "range", start, end]) = do
  start <- parseDT start
  end <- parseDT end
  return $ Explicit $ Set.singleton $ Interval.Closed start end
fromJSON (A [S "until", end]) = do
  end <- parseDT end
  return $ Explicit $ Set.singleton $ Interval.LeftOpen end
fromJSON (A [S "before", end]) = do
  end <- parseDT end
  return $ Explicit $ Set.singleton $ Interval.LeftOpen end
fromJSON (A [S "after", start]) = do
  start <- parseDT start
  return $ Explicit $ Set.singleton $ Interval.RightOpen start
fromJSON (A [S "always"]) = return $ Explicit $ Set.singleton Interval.Open
fromJSON (A (S "weekly" : days)) = do
  days <- traverse parseDay days
  return $ Weekly (Set.fromList days) False
fromJSON (A ((S "monthly") : (S "all") : months)) = do
  months <- traverse parseMonth months
  return $ Monthly $ Map.fromList $ mm <$> months
  where
    mm :: MonthOfYear -> (MonthOfYear, Set DayOfMonth)
    mm m = (m, Set.fromList [1..31])
fromJSON (A [S "monthly", A days, A months]) = do
  months <- traverse parseMonth months
  days <- parseDays days
  return $ Monthly $ Map.fromList $ mm days <$> months
  where
    mm :: Set DayOfMonth -> MonthOfYear -> (MonthOfYear, Set DayOfMonth)
    mm days m = (m, days)
fromJSON (A (S "monthly" : days)) = do
  days <- parseDays days
  return $ Monthly $ Map.fromList $ mm days <$> [1..12]
  where
    mm :: Set DayOfMonth -> MonthOfYear -> (MonthOfYear, Set DayOfMonth)
    mm days m = (m, days)
fromJSON (A [S "shift", offset, ds]) = do
  offset <- parseDuration offset
  wrapped <- fromJSON ds
  return $ Shift offset wrapped
fromJSON (A [S "++", period]) = do
  period <- parseDuration period
  return $ Periodic period Interval.day (fromInteger 0)
fromJSON (A [S "++", period, duration]) = do
  period <- parseDuration period
  duration <- parseDuration duration
  return $ Periodic period duration (fromInteger 0)
fromJSON (A [S "++", period, duration, phase]) = do
  period <- parseDuration period
  duration <- parseDuration duration
  phase <- parseDuration phase
  return $ Periodic period duration phase
fromJSON (A [S "@", time_, duration]) = do
  time_ <- parseTime time_
  duration <- parseDuration duration
  return $ AtTime time_ duration False
fromJSON (A (S "|" : subexprs)) = do
  subexprs <- traverse fromJSON subexprs
  return $ Union subexprs
fromJSON (A (S "&" : subexprs)) = do
  subexprs <- traverse fromJSON subexprs
  return $ Intersection subexprs
fromJSON (A [S "~", subexpr]) = do
  subexpr <- fromJSON subexpr
  return $ DateSet.invert subexpr
fromJSON (A [S "except", a, b]) = do
  a <- fromJSON a
  b <- fromJSON b
  return $ Intersection [a, b]
fromJSON e = error $ "Illegal date expr: " ++ show e
