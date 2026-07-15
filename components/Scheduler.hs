{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module Brainbox.Scheduler where

import Data.Ratio
import Text.JSON
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time.Clock
import Data.Time.Calendar.OrdinalDate
import Data.Time.Calendar
import Data.Time.Format.ISO8601
import Data.Time.LocalTime
import Text.Parse

import Util
import Interval

type DateTime = UTCTime
type TimeDelta = NominalDiffTime

-- | Represents when an event can happen.
--
-- We can ask a date set whether or not an arbitrary interval
-- intersects it, and we can ask for the set for all the intervals it
-- contains which intersect the window.
--
-- A DateSet can be finite or infinite. For finite sets, we can find
-- the span (i.e. bounding interval, or the smallest interval that
-- contains every interval in the set).
data DateSet
  = Explicit (Set Interval)
  | Union [DateSet]
  | Intersection [DateSet]
  | Periodic {period :: TimeDelta, duration :: TimeDelta, phase :: TimeDelta}
  | AtTime {start :: TimeOfDay, duration' :: TimeDelta, inverted :: Bool}
  | Weekly {which :: Set DayOfWeek, multi_day :: Bool}
  | Monthly {months :: Map MonthOfYear (Set DayOfMonth)}
  | NthWeekday {n :: Int, weekday :: DayOfWeek, month :: Maybe DayOfMonth}
  | Shift {offset :: TimeDelta, subset :: DateSet}
  deriving (Eq, Ord, Show)

-- | True if the dateset is finite.
finite :: DateSet -> Bool
finite (Explicit intervals) = all Interval.finite intervals
finite (Union subsets) = all Brainbox.Scheduler.finite subsets
finite (Intersection subsets) = any Brainbox.Scheduler.finite subsets
finite (Shift _ subset) = Brainbox.Scheduler.finite subset
finite _ = False

-- | True if window interesects any interval within the dateset.
intersects :: DateSet -> Interval -> Bool
intersects (Explicit intervals) i = any (Interval.intersects i) intervals
intersects (Union subsets) i = any (intersecting i) subsets
  where
    intersecting :: Interval -> DateSet -> Bool
    intersecting i ds  = Brainbox.Scheduler.intersects ds i
intersecting (Intersection subsets) i = all (intersecting i) subsets
  where
    intersecting :: Interval -> DateSet -> Bool
    intersecting i ds = Brainbox.Scheduler.intersects ds i

-- | Returns the smallest interval which contains the entire set.
span :: DateSet -> Interval
span _ = error "NotImplemented"

-- | A hint to the scheduler about the smallest time scales within the set.
resolution :: DateSet -> Interval
resolution _ = error "NotImplemented"

-- | True if the given dt is part of this set.
within :: DateSet -> DateTime -> Bool
within self dt = Interval.within (largestIntervalContaining self) dt

-- | True if the given window is completely contained by this set.
contains :: DateSet -> Interval -> Bool
contains _ = error "NotImplemented"

-- | Return an ordered sequence of intervals which intersect `window`.
--
-- If window is not given, and dateset is finite, then yields every
-- interval in the date set.
--
-- If this window is not given, and the dateset is not finite, this
-- will raise `ValueError'.
intervals :: DateSet -> Maybe Interval -> [Interval]
intervals _ = error "NotImplemented"

-- | Yield tuples of `(intervals, completed)`.
--
-- A single timestamp within an interval is considered a "completion
-- event", which discharges the obligation implied by the interval.
--
-- Multiple timestamps within an interval are ignored, as are
-- timestamps outside of a completion window.
--
-- `window` is treated the same as in `intervals`.
completions :: DateSet -> [DateTime] -> Maybe Interval -> [(Interval, Bool)]
completions self history window = completed <$> intervals self window
  where
    completed i = (i, any (Interval.within i) history)

-- | True if all intervals within the window have a completion event.
--
-- If `window` is `Nothing`, then:
--   - if self is finite     -- all intervals in dateset must be complete.
--   - else                  -- returns False
isComplete :: DateSet -> [DateTime] -> Maybe Interval -> Bool
isComplete self history window = case window of
  Nothing -> if Interval.finite (Brainbox.Scheduler.span self)
             then go Nothing
             else False
  window -> go window
  where
    go window = all snd $ completions self history window

-- | Find the largest interval within the dateset that contains the given time.
largestIntervalContaining :: DateSet -> Interval
largestIntervalContaining _ = error "NotImplemented"

-- | Return the inverse of the given date set.
invert :: DateSet -> DateSet
invert _ = error "Not implemented"

-- | Parse a string into a timedelta, using our custom notation.
parseDuration :: TextParser TimeDelta
parseDuration = do
  quant <- parseDec
  unit  <- oneOf (literal <$> ["w", "d", "h", "m", "s"])
  case unit of
    "d" -> return $ (fromInteger quant) * day
    "h" -> return $ (fromInteger quant) * hour
    "m" -> return $ (fromInteger quant) * second
    "w" -> return $ (fromInteger quant) * week
    _   -> failBad "Invalid Unit"

-- | Parse a snippet of JSON into a time delta, using our custom
-- notation and allowing for addition and subtraction of time intervals.
parseDuration' :: JExpr -> Either String TimeDelta
parseDuration' (S d) = fst $ runParser parseDuration d
parseDuration' (A [S "+", a, b]) = do
  a <- parseDuration' a
  b <- parseDuration' b
  return $ a + b
parseDuration' (A [S "-", a, b]) = do
  a <- parseDuration' a
  b <- parseDuration' b
  return $ a - b
parseDuration' e     = Left $ "Invalid duration: " ++ show e

-- | Parse a day abbreviation into a DayOfWeek value.
parseDay :: TextParser DayOfWeek
parseDay = do
  possible <- word
  case possible of
    "mon" -> return Monday
    "tue" -> return Tuesday
    "wed" -> return Wednesday
    "thu" -> return Thursday
    "fri" -> return Friday
    "sat" -> return Saturday
    "sun" -> return Sunday
    _     -> failBad "Invalid day of week"

-- | Parse a day abbreviation from a snippet of JSON.
--
-- XXX: Python weekdays set monday as 0, whereas the `time` package
-- sets monday at 1. Watch out!!
parseDay' :: JExpr -> Either String DayOfWeek
parseDay' (S day) = fst $ runParser parseDay day
parseDay' (I day) = if 0 <= day && day <= 6
                    then return $ toEnum $ mod (day + 1) 7
                    else Left $ "Invalid weekday: " ++ show day
parseDay' err     = Left $ "Invalid weekday: " ++ show err

-- | Parse a month abbreviation from a string.
parseMonth :: TextParser MonthOfYear
parseMonth = do
  possible <- word
  case possible of
    "jan" -> return January
    "feb" -> return February
    "mar" -> return March
    "apr" -> return April
    "may" -> return May
    "jun" -> return June
    "jul" -> return July
    "aug" -> return August
    "sep" -> return September
    "oct" -> return October
    "nov" -> return November
    "dec" -> return December

-- | Parse a month abbreviation from a string.
parseMonth' :: JExpr -> Either String MonthOfYear
parseMonth' (S mon) = fst $ runParser parseMonth mon
parseMonth' err     = Left $ "Invalid month: " ++ show err

{-
parseDays :: TextParser DateSet
parseDays = oneOf [dayRange, dayList]
  where
    dayRange = do
      start <- parseDay
      oneOf [literal "-", literal "to"]
      end <- parseDay
      return $ Explicit $ Set.fromList [start .. end]

    dayList = do
      days <- sepBy1 parseDay (literal ",")
      return $ Explicit $ Set.fromList days
-}

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

instance MonadFail (Either String) where
  fail = Left

parseDT :: JExpr -> Either String DateTime
parseDT (S date) = iso8601ParseM date
parseDT e = Left $ "Invalid datetime: " ++ show e

parseTime :: JExpr -> Either String TimeOfDay
parseTime (S time) = iso8601ParseM time
parseTime (I hour) = if 0 <= hour && hour <= 23
  then Right $ TimeOfDay hour 0 0
  else Left $ "Invalid hour: " ++ show hour
parseTime (A [S "+", a, b]) = do
  a <- parseTime a
  b <- parseDuration' b
  case timeToDaysAndTimeOfDay $ (daysAndTimeOfDayToTime 0 a) + b of
    (0, time_) -> return time_
    (_, _)     -> Left $ "Time overflow: " ++ show b
parseTime (A [S "-", a, b]) = do
  a <- parseTime a
  b <- parseDuration' b
  case timeToDaysAndTimeOfDay $ (daysAndTimeOfDayToTime 0 a) - b of
    (0, time_) -> return time_
    (_, _)     -> Left $ "Time overflow: " ++ show b
parseTime e = Left $ "Invalid time of day: " ++ show e

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
  return $ Explicit $ Set.singleton $ LeftOpen end
fromJSON (A [S "before", end]) = do
  end <- parseDT end
  return $ Explicit $ Set.singleton $ LeftOpen end
fromJSON (A [S "after", start]) = do
  start <- parseDT start
  return $ Explicit $ Set.singleton $ RightOpen start
fromJSON (A [S "always"]) = return $ Explicit $ Set.singleton Open
fromJSON (A (S "weekly" : days)) = do
  days <- traverse parseDay' days
  return $ Weekly (Set.fromList days) False
fromJSON (A ((S "monthly") : (S "all") : months)) = do
  months <- traverse parseMonth' months
  return $ Monthly $ Map.fromList $ mm <$> months
  where
    mm :: MonthOfYear -> (MonthOfYear, Set DayOfMonth)
    mm m = (m, Set.fromList [1..31])
fromJSON (A [S "monthly", A days, A months]) = do
  months <- traverse parseMonth' months
  days <- traverse validateDay days
  return $ Monthly $ Map.fromList $ mm (Set.fromList days) <$> months
  where
    validateDay (I d) = case d >= 1 && d <= 31 of
      True -> Right d
      False -> Left $ "Invalid day of month: " ++ show d
    validateDay e = Left $ "Invalid day of month: " ++ show e

    mm :: Set DayOfMonth -> MonthOfYear -> (MonthOfYear, Set DayOfMonth)
    mm days m = (m, days)
fromJSON (A (S "monthly" : days)) = do
  days <- traverse validateDay days
  return $ Monthly $ Map.fromList $ mm (Set.fromList days) <$> [1..12]
  where
    validateDay (I d) = case d >= 1 && d <= 31 of
      True -> Right d
      False -> Left $ "Invalid day of month: " ++ show d
    validateDay e = Left $ "Invalid day of month: " ++ show e

    mm :: Set DayOfMonth -> MonthOfYear -> (MonthOfYear, Set DayOfMonth)
    mm days m = (m, days)
fromJSON (A [S "shift", offset, ds]) = do
  offset <- parseDuration' offset
  wrapped <- fromJSON ds
  return $ Shift offset wrapped
fromJSON (A [S "++", period]) = do
  period <- parseDuration' period
  return $ Periodic period day (fromInteger 0)
fromJSON (A [S "++", period, duration]) = do
  period <- parseDuration' period
  duration <- parseDuration' duration
  return $ Periodic period duration (fromInteger 0)
fromJSON (A [S "++", period, duration, phase]) = do
  period <- parseDuration' period
  duration <- parseDuration' duration
  phase <- parseDuration' phase
  return $ Periodic period duration phase
fromJSON (A [S "@", time_, duration]) = do
  time_ <- parseTime time_
  duration <- parseDuration' duration
  return $ AtTime time_ duration False
fromJSON (A (S "|" : subexprs)) = do
  subexprs <- traverse fromJSON subexprs
  return $ Union subexprs
fromJSON (A (S "&" : subexprs)) = do
  subexprs <- traverse fromJSON subexprs
  return $ Intersection subexprs
fromJSON (A [S "~", subexpr]) = do
  subexpr <- fromJSON subexpr
  return $ Brainbox.Scheduler.invert subexpr
fromJSON (A [S "except", a, b]) = do
  a <- fromJSON a
  b <- fromJSON b
  return $ Intersection [a, b]
fromJSON e = error $ "Illegal date expr: " ++ show e

main :: IO ()
main = error "not implemented"
